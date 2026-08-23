/**
A composable Cartesian grid backdrop (`GRD`): major/minor lattice and stripe
bands, line or dotted-graph-paper marks, stroke styling, and cyclic X/Y
stripe brushes.

Pure config + emit. Callers (a diagram board, the gallery, any other
`sparkles:ui` surface) supply a $(LREF GridView) — screen rect, visible world
rect, and the integer cell mapping — and receive $(REF DrawOp, sparkles,ui,canvas)s.
The component never names a backend, a host, or an application world.

Colours stay on theme $(REF Slot, sparkles,ui,style)s (`RND5` / `GRD10`): a
brush is transparent or a slot; alphas live on the palette.
*/
module sparkles.ui.components.grid_backdrop;

import std.json : JSONValue;

import sparkles.base.term_color : Color, RgbColor;
import sparkles.ui.canvas : DrawOp, fillRectOp, glyphOp, OpKind, ruleOp,
    RuleEdge;
import sparkles.ui.geometry : Point, Rect;
// The config carries its own editor metadata (`SET4`): one declaration, so a
// settings pane over this type cannot describe a field the component dropped.
import sparkles.ui.property_tree : Doc, Label, Range;
import sparkles.ui.style : Palette, resolveSlot, Slot, Visual;

@safe:

/// Which axes a subdivision layer paints.
enum AxisVisibility : ubyte
{
    none, /// hidden
    x,    /// verticals / X bands only
    y,    /// horizontals / Y bands only
    xy,   /// both axes
}

/// How the lattice is marked (`GRD3`, `GRD4`).
enum MarkKind : ubyte
{
    lines, /// continuous axis rules
    dots,  /// marks only at lattice intersections (graph paper)
}

/// Named fixtures (`GRD` acceptance + gallery presets).
enum GridPreset : ubyte
{
    defaultLines, /// pre-`GRD` `RND4` faint line grid
    stripeBands,  /// lines plus cyclic X/Y translucent bands
    dotPaper,     /// dotted graph paper, optional major accent every 4
}

/// Cap on a stripe-brush cycle and on a dash array — keeps emit `@nogc`.
enum size_t stripeBrushCap = 8;
/// ditto
enum size_t dashCap = 8;

/// One subdivision layer: visibility + world-cell interval (`GRD2`).
struct AxisSubdivision
{
    @Label("Axes") @Doc("Which axes this layer paints.")
    AxisVisibility visibility = AxisVisibility.none;
    /// world cells; must be positive when the layer is on
    @Label("Interval")
    @Doc("Spacing in world cells. Drives line spacing and stripe band width.")
    @Range(1, 1024, 1)
    int interval = 1;
}

/// Stroke / mark appearance for one lattice layer (`GRD3`).
struct LatticeStyle
{
    @Label("Marks")
    @Doc("Continuous rules, or marks only at intersections (graph paper).")
    MarkKind markKind;
    @Label("Stroke slot")
    @Doc("Theme slot the stroke resolves through — never a free colour.")
    Slot stroke = Slot.muted;
    /// Stroke width for `lines`, mark size for `dots` (1 = hairline / `·`).
    @Label("Thickness") @Doc("Stroke width for lines, mark size for dots.")
    @Range(1, 16, 1)
    int thickness = 1;
    /// On/off cell lengths for `lines`. `dashCount == 0` is solid.
    @Label("Dash cells") @Doc("On/off cell lengths; ignored for dots.")
    ubyte[dashCap] dash;
    @Label("Dash length") @Doc("How many dash entries are live. 0 is solid.")
    @Range(0, dashCap, 1)
    ubyte dashCount;
}

/// One stripe-band fill: skip, or paint this slot's background (`GRD5`).
struct StripeBrush
{
    @Label("Transparent") @Doc("Skip this band — paint nothing.")
    bool transparent = true;
    @Label("Fill slot") @Doc("Theme slot whose background + bg alpha fills the band.")
    Slot slot = Slot.inherit;
}

/// Cyclic X and Y stripe brushes.
struct StripeBrushes
{
    @Label("X cycle") @Doc("Bands along the X axis, cycled per interval.")
    StripeBrush[stripeBrushCap] x;
    @Label("X entries") @Doc("How much of the X cycle is live.")
    @Range(0, stripeBrushCap, 1)
    ubyte xCount;
    @Label("Y cycle") @Doc("Bands along the Y axis; painted over X bands.")
    StripeBrush[stripeBrushCap] y;
    @Label("Y entries") @Doc("How much of the Y cycle is live.")
    @Range(0, stripeBrushCap, 1)
    ubyte yCount;
}

/**
The whole backdrop configuration. `GridConfig.init` is the `RND4` default.

The fields carry their own $(MREF sparkles,ui,property_tree) metadata, so an
editor over this type — `apps/diagram`'s settings pane (`SET4`), a gallery
control — is generated from the declaration rather than re-describing it. A
field added here is a row there; there is no second place to update.
*/
struct GridConfig
{
    @Label("Minor lattice") @Doc("The fine grid: every `interval` world cells.")
    AxisSubdivision minorLattice = AxisSubdivision(AxisVisibility.xy, 1);
    @Label("Major lattice") @Doc("The accent grid, drawn over the minor one.")
    AxisSubdivision majorLattice = AxisSubdivision(AxisVisibility.xy, 8);
    @Label("Minor stripes") @Doc("Narrow bands under the lattice.")
    AxisSubdivision minorStripes;
    @Label("Major stripes") @Doc("Wide bands, painted under the minor ones.")
    AxisSubdivision majorStripes;
    @Label("Minor style") LatticeStyle minorStyle = LatticeStyle(MarkKind.lines, Slot.muted, 1);
    @Label("Major style") LatticeStyle majorStyle = LatticeStyle(MarkKind.lines, Slot.border, 1);
    @Label("Stripe brushes") StripeBrushes brushes;
}

/**
Where the backdrop is painted, in the same integer cell mapping a board
camera uses (`CAM1`): `origin` is the world cell at `screen`'s top-left.
The cell mapping never reads a mantissa — `worldPerCell` / `cellsPerWorld`
are the exponent only.
*/
struct GridView
{
    Rect screen;           /// destination, in surface cells
    Rect world;            /// visible world rect (cull)
    Point origin;          /// world cell at `screen` top-left
    int worldPerCell = 1;  /// world cells sharing one screen cell (≥ 1)
    int cellsPerWorld = 1; /// screen cells covering one world cell (≥ 1)
}

/// A transparent brush entry.
StripeBrush transparentBrush() @safe pure nothrow @nogc => StripeBrush.init;

/// A slot brush (uses the slot's background + bg alpha).
StripeBrush slotBrush(Slot slot) @safe pure nothrow @nogc
    => StripeBrush(transparent: false, slot: slot);

/// Whether `v` paints the X axis (verticals / X bands).
bool showsX(AxisVisibility v) @safe pure nothrow @nogc
    => v == AxisVisibility.x || v == AxisVisibility.xy;

/// Whether `v` paints the Y axis (horizontals / Y bands).
bool showsY(AxisVisibility v) @safe pure nothrow @nogc
    => v == AxisVisibility.y || v == AxisVisibility.xy;

/// The `RND4` / default-lines fixture.
GridConfig gridPreset(GridPreset p) @safe pure nothrow @nogc
{
    GridConfig cfg;
    final switch (p)
    {
        case GridPreset.defaultLines:
            return cfg;
        case GridPreset.stripeBands:
            cfg.majorStripes = AxisSubdivision(AxisVisibility.xy, 8);
            cfg.brushes.x[0] = transparentBrush();
            cfg.brushes.x[1] = slotBrush(Slot.warn);
            cfg.brushes.xCount = 2;
            cfg.brushes.y[0] = slotBrush(Slot.error);
            cfg.brushes.y[1] = slotBrush(Slot.annotate);
            cfg.brushes.y[2] = transparentBrush();
            cfg.brushes.yCount = 3;
            return cfg;
        case GridPreset.dotPaper:
            cfg.minorStyle = LatticeStyle(MarkKind.dots, Slot.info, 1);
            cfg.majorStyle = LatticeStyle(MarkKind.dots, Slot.info, 2);
            cfg.majorLattice.interval = 4;
            return cfg;
    }
}

/// World → surface, matching diagram's camera (`divFloor` toward −∞).
Point gridWorldToScreen(in GridView view, in Point world) @safe pure nothrow @nogc
{
    const wpc = view.worldPerCell > 0 ? view.worldPerCell : 1;
    const cpw = view.cellsPerWorld > 0 ? view.cellsPerWorld : 1;
    return Point(
        view.screen.x + divFloor(world.x - view.origin.x, wpc) * cpw,
        view.screen.y + divFloor(world.y - view.origin.y, wpc) * cpw);
}

/**
Effective lattice step in world cells: never denser than one screen cell, and
major stays a whole multiple of the effective minor so a zoomed-out board
keeps "a major every N minors" (`RND4`).
*/
int effectiveMinorStep(in GridConfig cfg, in GridView view) @safe pure nothrow @nogc
{
    const i = cfg.minorLattice.interval > 0 ? cfg.minorLattice.interval : 1;
    const wpc = view.worldPerCell > 0 ? view.worldPerCell : 1;
    return i > wpc ? i : wpc;
}

/// ditto
int majorMultipleOf(in GridConfig cfg) @safe pure nothrow @nogc
{
    const mi = cfg.minorLattice.interval > 0 ? cfg.minorLattice.interval : 1;
    const ma = cfg.majorLattice.interval > 0 ? cfg.majorLattice.interval : mi;
    const m = ma / mi;
    return m > 0 ? m : 1;
}

/// ditto
int effectiveMajorStep(in GridConfig cfg, in GridView view) @safe pure nothrow @nogc
    => effectiveMinorStep(cfg, view) * majorMultipleOf(cfg);

/// Stripe-layer step: never denser than one screen cell.
int effectiveStripeStep(in AxisSubdivision layer, in GridView view)
    @safe pure nothrow @nogc
{
    const i = layer.interval > 0 ? layer.interval : 1;
    const wpc = view.worldPerCell > 0 ? view.worldPerCell : 1;
    return i > wpc ? i : wpc;
}

/**
Appends the backdrop into `ops` (`GRD1`, `GRD6`): major then minor stripes
(X under Y), then minor then major lattice. Slots resolve through `pal`.

$(B `maxOps` is a real budget, and a lattice that will not fit it is dropped
whole.) A `lines` layer costs one op per visible row or column; a `dots` layer
costs one per lattice $(I intersection), so the same config that is a hundred
ops as lines is tens of thousands as graph paper on a large surface. A host
that appends this into a bounded frame buffer therefore has to be able to say
how much of it the backdrop may spend — otherwise the backdrop spends the
frame and whatever the host draws afterwards (its chrome, its content) is what
disappears.

Dropped $(B whole), never truncated: half a lattice would put marks in some
places and not others at the same interval, which is a lie about where the
lattice is (`GRD6`) rather than a degradation of it. The major layer is
charged for first, so when a dense minor lattice cannot fit it is the fine
layer that goes and the coarse accents that survive — the way a board thins
its grid as it zooms out.
*/
void appendGridBackdrop(Sink)(
    ref Sink ops, in GridConfig cfg, in GridView view,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg,
    size_t maxOps = size_t.max)
{
    if (view.screen.empty || view.world.empty)
        return;

    const minorStep = effectiveMinorStep(cfg, view);
    const majorStep = effectiveMajorStep(cfg, view);
    const majorCost = latticeCost(cfg.majorLattice, cfg.majorStyle,
        majorStep, view);
    const minorRoom = maxOps > majorCost ? maxOps - majorCost : 0;

    paintStripes(ops, cfg.majorStripes, cfg.brushes, view, pal, pageFg, pageBg);
    paintStripes(ops, cfg.minorStripes, cfg.brushes, view, pal, pageFg, pageBg);
    if (latticeCost(cfg.minorLattice, cfg.minorStyle, minorStep, view)
            <= minorRoom)
        paintLattice(ops, cfg.minorLattice, cfg.minorStyle, minorStep, view,
            pal, pageFg, pageBg);
    if (majorCost <= maxOps)
        paintLattice(ops, cfg.majorLattice, cfg.majorStyle, majorStep, view,
            pal, pageFg, pageBg);
}

/**
An upper bound on the ops one lattice layer will append (`GRD1`).

Never an underestimate — both emitters de-duplicate by screen cell, so the
screen's own extent bounds them, and the world span bounds them again when the
interval is coarse. `lines` is a sum (rows plus columns); `dots` is a product
(one mark per intersection), which is the whole reason a budget exists.
*/
size_t latticeCost(in AxisSubdivision layer, in LatticeStyle style, int step,
    in GridView view) @safe pure nothrow @nogc
{
    if (layer.visibility == AxisVisibility.none || step <= 0)
        return 0;
    const gx = showsX(layer.visibility);
    const gy = showsY(layer.visibility);

    static size_t spans(int worldSpan, int screenSpan, int step_)
        @safe pure nothrow @nogc
    {
        if (worldSpan <= 0 || screenSpan <= 0)
            return 0;
        const byWorld = cast(size_t)((worldSpan + step_ - 1) / step_);
        const byScreen = cast(size_t) screenSpan;
        return byWorld < byScreen ? byWorld : byScreen;
    }

    const cols = spans(view.world.width, view.screen.width, step);
    const rows = spans(view.world.height, view.screen.height, step);

    if (style.markKind == MarkKind.dots)
        return (gx ? cols : 1) * (gy ? rows : 1);
    return (gx ? cols : 0) + (gy ? rows : 0);
}

/// Dot glyph for a mark size: `·` (U+00B7) at 1, `•` (U+2022) when thicker.
dchar gridDotGlyph(int thickness) @safe pure nothrow @nogc
    => thickness > 1 ? '\u2022' : '\u00b7';

/**
A 1:1 widget preview of `cfg` in a fixed `width` × `height` cell box — the
composition path for the gallery (`GRD11`). Camera-mapped boards use
$(LREF appendGridBackdrop).
*/
uint buildGridPreview(B)(ref B b, in GridConfig cfg, int width, int height)
{
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.widget : Widget, WidgetKind;

    if (width < 1)
        width = 1;
    if (height < 1)
        height = 1;
    GridView view = {
        screen: Rect(0, 0, width, height),
        world: Rect(0, 0, width, height),
    };
    uint[] layers;
    layers ~= b.add(Widget(
        kind: WidgetKind.box,
        width: SizeSpec.fixed(width),
        height: SizeSpec.fixed(height),
        slot: Slot.inherit,
        paintBackground: true,
    ));

    void stripeX(in AxisSubdivision layer)
    {
        if (!showsX(layer.visibility) || cfg.brushes.xCount == 0)
            return;
        const step = effectiveStripeStep(layer, view);
        uint[] cells;
        int x, idx;
        while (x < width)
        {
            const w = step < width - x ? step : width - x;
            const brush = cfg.brushes.x[posMod(idx, cfg.brushes.xCount)];
            cells ~= b.add(Widget(
                kind: WidgetKind.box,
                width: SizeSpec.fixed(w),
                height: SizeSpec.fixed(height),
                slot: brush.transparent ? Slot.inherit : brush.slot,
                paintBackground: !brush.transparent,
            ));
            x += w;
            ++idx;
        }
        layers ~= b.add(Widget(
            kind: WidgetKind.row,
            children: cells,
            width: SizeSpec.fixed(width),
            height: SizeSpec.fixed(height),
        ));
    }

    void stripeY(in AxisSubdivision layer)
    {
        if (!showsY(layer.visibility) || cfg.brushes.yCount == 0)
            return;
        const step = effectiveStripeStep(layer, view);
        uint[] cells;
        int y, idx;
        while (y < height)
        {
            const h = step < height - y ? step : height - y;
            const brush = cfg.brushes.y[posMod(idx, cfg.brushes.yCount)];
            cells ~= b.add(Widget(
                kind: WidgetKind.box,
                width: SizeSpec.fixed(width),
                height: SizeSpec.fixed(h),
                slot: brush.transparent ? Slot.inherit : brush.slot,
                paintBackground: !brush.transparent,
            ));
            y += h;
            ++idx;
        }
        layers ~= b.add(Widget(
            kind: WidgetKind.column,
            children: cells,
            width: SizeSpec.fixed(width),
            height: SizeSpec.fixed(height),
        ));
    }

    void lattice(in AxisSubdivision layer, in LatticeStyle style, int step)
    {
        if (layer.visibility == AxisVisibility.none || step <= 0)
            return;
        if (style.markKind == MarkKind.dots)
        {
            uint[] rows;
            const gx = showsX(layer.visibility);
            const gy = showsY(layer.visibility);
            const dx = gx ? step : width;
            const dy = gy ? step : height;
            const glyph = gridDotGlyph(style.thickness);
            for (int y = 0; y < height; y += dy)
            {
                uint[] cells;
                int x;
                if (gx)
                {
                    while (x < width)
                    {
                        cells ~= b.add(Widget(
                            kind: WidgetKind.glyph,
                            glyph: glyph,
                            slot: style.stroke,
                            width: SizeSpec.fixed(1),
                            height: SizeSpec.fixed(1),
                        ));
                        const pad = dx - 1;
                        if (pad > 0 && x + 1 < width)
                        {
                            const pw = pad < width - x - 1 ? pad : width - x - 1;
                            cells ~= b.add(Widget(
                                kind: WidgetKind.box,
                                width: SizeSpec.fixed(pw),
                                height: SizeSpec.fixed(1),
                            ));
                            x += 1 + pw;
                        }
                        else
                            x += 1;
                    }
                }
                else
                {
                    cells ~= b.add(Widget(
                        kind: WidgetKind.glyph,
                        glyph: glyph,
                        slot: style.stroke,
                    ));
                }
                rows ~= b.add(Widget(kind: WidgetKind.row, children: cells,
                    width: SizeSpec.fixed(width), height: SizeSpec.fixed(1)));
                const vpad = dy - 1;
                if (vpad > 0 && y + 1 < height)
                {
                    const ph = vpad < height - y - 1 ? vpad : height - y - 1;
                    rows ~= b.add(Widget(
                        kind: WidgetKind.box,
                        width: SizeSpec.fixed(width),
                        height: SizeSpec.fixed(ph),
                    ));
                }
            }
            layers ~= b.add(Widget(
                kind: WidgetKind.column,
                children: rows,
                width: SizeSpec.fixed(width),
                height: SizeSpec.fixed(height),
            ));
            return;
        }
        if (showsY(layer.visibility))
        {
            uint[] rows;
            int y;
            while (y < height)
            {
                rows ~= b.add(Widget(
                    kind: WidgetKind.box,
                    width: SizeSpec.fixed(width),
                    height: SizeSpec.fixed(1),
                    slot: style.stroke,
                    paintBackground: true,
                ));
                y += 1;
                const gap = step - 1;
                if (gap > 0 && y < height)
                {
                    const gh = gap < height - y ? gap : height - y;
                    rows ~= b.add(Widget(
                        kind: WidgetKind.box,
                        width: SizeSpec.fixed(width),
                        height: SizeSpec.fixed(gh),
                    ));
                    y += gh;
                }
            }
            layers ~= b.add(Widget(
                kind: WidgetKind.column,
                children: rows,
                width: SizeSpec.fixed(width),
                height: SizeSpec.fixed(height),
            ));
        }
        if (showsX(layer.visibility))
        {
            uint[] cols;
            int x;
            while (x < width)
            {
                cols ~= b.add(Widget(
                    kind: WidgetKind.box,
                    width: SizeSpec.fixed(1),
                    height: SizeSpec.fixed(height),
                    slot: style.stroke,
                    paintBackground: true,
                ));
                x += 1;
                const gap = step - 1;
                if (gap > 0 && x < width)
                {
                    const gw = gap < width - x ? gap : width - x;
                    cols ~= b.add(Widget(
                        kind: WidgetKind.box,
                        width: SizeSpec.fixed(gw),
                        height: SizeSpec.fixed(height),
                    ));
                    x += gw;
                }
            }
            layers ~= b.add(Widget(
                kind: WidgetKind.row,
                children: cols,
                width: SizeSpec.fixed(width),
                height: SizeSpec.fixed(height),
            ));
        }
    }

    stripeX(cfg.majorStripes);
    stripeY(cfg.majorStripes);
    stripeX(cfg.minorStripes);
    stripeY(cfg.minorStripes);
    lattice(cfg.minorLattice, cfg.minorStyle, effectiveMinorStep(cfg, view));
    lattice(cfg.majorLattice, cfg.majorStyle, effectiveMajorStep(cfg, view));

    return b.add(Widget(
        kind: WidgetKind.stack,
        children: layers,
        width: SizeSpec.fixed(width),
        height: SizeSpec.fixed(height),
        clipX: true,
        clipY: true,
    ));
}

// ── emit internals ──────────────────────────────────────────────────────────

private void paintStripes(Sink)(
    ref Sink ops, in AxisSubdivision layer, in StripeBrushes brushes,
    in GridView view, in Palette pal, in RgbColor pageFg, in RgbColor pageBg)
{
    if (layer.visibility == AxisVisibility.none)
        return;
    const step = effectiveStripeStep(layer, view);
    if (step <= 0)
        return;

    if (showsX(layer.visibility) && brushes.xCount > 0)
    {
        int wx = floorMultiple(view.world.x, step);
        // Walk one extra step so a band that starts left of the cull still
        // covers the visible left edge.
        if (wx > view.world.x - step)
            wx -= step;
        for (; wx < view.world.right; wx += step)
        {
            const brush = brushes.x[posMod(divFloor(wx, step), brushes.xCount)];
            if (brush.transparent)
                continue;
            const a = gridWorldToScreen(view, Point(wx, view.world.y));
            const b = gridWorldToScreen(view, Point(wx + step, view.world.y));
            int x = a.x;
            int w = b.x - a.x;
            if (w < 1)
                w = 1;
            auto r = Rect(x, view.screen.y, w, view.screen.height)
                .intersection(view.screen);
            fillSlot(ops, r, brush.slot, pal, pageFg, pageBg);
        }
    }
    if (showsY(layer.visibility) && brushes.yCount > 0)
    {
        int wy = floorMultiple(view.world.y, step);
        if (wy > view.world.y - step)
            wy -= step;
        for (; wy < view.world.bottom; wy += step)
        {
            const brush = brushes.y[posMod(divFloor(wy, step), brushes.yCount)];
            if (brush.transparent)
                continue;
            const a = gridWorldToScreen(view, Point(view.world.x, wy));
            const b = gridWorldToScreen(view, Point(view.world.x, wy + step));
            int y = a.y;
            int h = b.y - a.y;
            if (h < 1)
                h = 1;
            auto r = Rect(view.screen.x, y, view.screen.width, h)
                .intersection(view.screen);
            fillSlot(ops, r, brush.slot, pal, pageFg, pageBg);
        }
    }
}

private void paintLattice(Sink)(
    ref Sink ops, in AxisSubdivision layer, in LatticeStyle style,
    int step, in GridView view,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg)
{
    if (layer.visibility == AxisVisibility.none)
        return;
    if (step <= 0)
        return;

    const vis = resolveSlot(pal, style.stroke, pageFg, pageBg);

    if (style.markKind == MarkKind.dots)
    {
        paintDots(ops, layer, style, step, view, vis);
        return;
    }
    if (showsX(layer.visibility))
    {
        int wx = floorMultiple(view.world.x, step);
        int lastSx = int.min;
        for (; wx < view.world.right; wx += step)
        {
            const sx = gridWorldToScreen(view, Point(wx, view.world.y)).x;
            if (sx == lastSx)
                continue;
            lastSx = sx;
            if (sx < view.screen.x || sx >= view.screen.right)
                continue;
            strokeV(ops, sx, view.screen.y, view.screen.height, style, vis);
        }
    }
    if (showsY(layer.visibility))
    {
        int wy = floorMultiple(view.world.y, step);
        int lastSy = int.min;
        for (; wy < view.world.bottom; wy += step)
        {
            const sy = gridWorldToScreen(view, Point(view.world.x, wy)).y;
            if (sy == lastSy)
                continue;
            lastSy = sy;
            if (sy < view.screen.y || sy >= view.screen.bottom)
                continue;
            strokeH(ops, view.screen.x, sy, view.screen.width, style, vis);
        }
    }
}

private void paintDots(Sink)(
    ref Sink ops, in AxisSubdivision layer, in LatticeStyle style,
    int step, in GridView view, in Visual vis)
{
    // Dots need a 2-D lattice. `xy` is the graph-paper case; `x` / `y` alone
    // collapse the other axis onto the view origin so the mode stays defined.
    const xStep = showsX(layer.visibility) ? step : 0;
    const yStep = showsY(layer.visibility) ? step : 0;
    if (xStep == 0 && yStep == 0)
        return;

    int x0 = showsX(layer.visibility)
        ? floorMultiple(view.world.x, step)
        : view.origin.x;
    int y0 = showsY(layer.visibility)
        ? floorMultiple(view.world.y, step)
        : view.origin.y;
    const x1 = showsX(layer.visibility) ? view.world.right : x0 + 1;
    const y1 = showsY(layer.visibility) ? view.world.bottom : y0 + 1;
    const dx = showsX(layer.visibility) ? step : 1;
    const dy = showsY(layer.visibility) ? step : 1;
    const glyph = gridDotGlyph(style.thickness);

    int lastSx = int.min;
    for (int wx = x0; wx < x1; wx += dx)
    {
        const sx = gridWorldToScreen(view, Point(wx, y0)).x;
        if (sx == lastSx)
            continue;
        lastSx = sx;
        if (sx < view.screen.x || sx >= view.screen.right)
            continue;
        int lastSy = int.min;
        for (int wy = y0; wy < y1; wy += dy)
        {
            const sy = gridWorldToScreen(view, Point(x0, wy)).y;
            if (sy == lastSy)
                continue;
            lastSy = sy;
            if (sy < view.screen.y || sy >= view.screen.bottom)
                continue;
            emitGlyph(ops, Point(sx, sy), glyph, style.stroke, vis);
        }
    }
}

private void strokeV(Sink)(
    ref Sink ops, int x, int y, int h, in LatticeStyle style, in Visual vis)
{
    if (h <= 0)
        return;
    const thick = style.thickness > 1 ? style.thickness : 1;
    if (style.dashCount == 0 && thick == 1)
    {
        emitRule(ops, Rect(x, y, 1, h), RuleEdge.left, style.stroke, vis);
        return;
    }
    // Dashed and/or thick: paint per-cell so both arms share one geometry.
    foreach (i; 0 .. h)
    {
        if (!dashOn(style, i))
            continue;
        const r = Rect(x, y + i, thick, 1);
        if (thick == 1)
            emitRule(ops, r, RuleEdge.left, style.stroke, vis);
        else
            emitFill(ops, r, style.stroke, vis);
    }
}

private void strokeH(Sink)(
    ref Sink ops, int x, int y, int w, in LatticeStyle style, in Visual vis)
{
    if (w <= 0)
        return;
    const thick = style.thickness > 1 ? style.thickness : 1;
    if (style.dashCount == 0 && thick == 1)
    {
        emitRule(ops, Rect(x, y, w, 1), RuleEdge.top, style.stroke, vis);
        return;
    }
    foreach (i; 0 .. w)
    {
        if (!dashOn(style, i))
            continue;
        const r = Rect(x + i, y, 1, thick);
        if (thick == 1)
            emitRule(ops, r, RuleEdge.top, style.stroke, vis);
        else
            emitFill(ops, r, style.stroke, vis);
    }
}

private bool dashOn(in LatticeStyle style, int index) @safe pure nothrow @nogc
{
    if (style.dashCount == 0)
        return true;
    int period;
    foreach (i; 0 .. style.dashCount)
        period += style.dash[i];
    if (period <= 0)
        return true;
    int phase = index % period;
    if (phase < 0)
        phase += period;
    int acc;
    foreach (i; 0 .. style.dashCount)
    {
        acc += style.dash[i];
        if (phase < acc)
            return (i % 2) == 0; // even entries are "on"
    }
    return true;
}

private void fillSlot(Sink)(
    ref Sink ops, in Rect r, Slot slot,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg)
{
    if (r.empty)
        return;
    auto vis = resolveSlot(pal, slot, pageFg, pageBg);
    if (!vis.hasBg || vis.bgAlpha == 0)
        return;
    emitFill(ops, r, slot, vis);
}

private void emitFill(Sink)(ref Sink ops, in Rect r, Slot slot, in Visual vis)
{
    if (r.empty)
        return;
    ops ~= fillRectOp(r, slot, vis);
}

private void emitRule(Sink)(
    ref Sink ops, in Rect r, RuleEdge edge, Slot slot, in Visual vis)
{
    ops ~= ruleOp(r, edge, slot, vis);
}

private void emitGlyph(Sink)(
    ref Sink ops, in Point at, dchar g, Slot slot, in Visual vis)
{
    ops ~= glyphOp(at, g, slot, vis);
}

private int divFloor(int a, int b) @safe pure nothrow @nogc
{
    if (b == 0)
        return 0;
    const q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

private int floorMultiple(int v, int step) @safe pure nothrow @nogc
{
    if (step <= 0)
        return v;
    return divFloor(v, step) * step;
}

private int posMod(int i, int n) @safe pure nothrow @nogc
{
    if (n <= 0)
        return 0;
    const r = i % n;
    return r < 0 ? r + n : r;
}

// ── JSON schema (shared by --config-file, settings persist, tests) ──────────

/**
Parses a grid-config JSON document into `cfg`.

Optional keys: `preset` (applied first), the four subdivision objects
(`minorLattice` / `majorLattice` / `minorStripes` / `majorStripes` with
`visibility` + `interval`), `minorStyle` / `majorStyle` (`markKind`,
`stroke`, `thickness`, `dash`), `xBrushes` / `yBrushes` (array of
`"transparent"` or a slot name), and `slotOverrides` (`slot`, optional
`fg`/`bg` hex, `fgAlpha`/`bgAlpha`) applied to `pal`.

Returns `false` and writes `error` on failure — fail closed (`GRD8`).
*/
bool parseGridConfigJson(const(char)[] text, ref GridConfig cfg, ref Palette pal,
    ref string error)
{
    import std.json : JSONException, JSONType, JSONValue, parseJSON;

    JSONValue root;
    try
        root = parseJSON(text);
    catch (JSONException ex)
    {
        error = "grid config: invalid JSON: " ~ ex.msg;
        return false;
    }
    if (root.type != JSONType.object)
    {
        error = "grid config: expected a JSON object";
        return false;
    }

    // Work on copies so a late error cannot half-apply (`GRD8`).
    GridConfig next = cfg;
    Palette nextPal = pal;
    auto obj = jsonObject(root);

    if (auto p = "preset" in obj)
    {
        if (p.type != JSONType.string)
        {
            error = "grid config: preset must be a string";
            return false;
        }
        GridPreset preset;
        if (!parsePreset(p.str, preset))
        {
            error = "grid config: unknown preset '" ~ p.str ~ "'";
            return false;
        }
        next = gridPreset(preset);
    }

    if (!readSubdivision(obj, "minorLattice", next.minorLattice, error))
        return false;
    if (!readSubdivision(obj, "majorLattice", next.majorLattice, error))
        return false;
    if (!readSubdivision(obj, "minorStripes", next.minorStripes, error))
        return false;
    if (!readSubdivision(obj, "majorStripes", next.majorStripes, error))
        return false;
    if (!readStyle(obj, "minorStyle", next.minorStyle, error))
        return false;
    if (!readStyle(obj, "majorStyle", next.majorStyle, error))
        return false;
    if (!readBrushes(obj, "xBrushes", next.brushes.x, next.brushes.xCount, error))
        return false;
    if (!readBrushes(obj, "yBrushes", next.brushes.y, next.brushes.yCount, error))
        return false;

    if (auto ovs = "slotOverrides" in obj)
    {
        if (ovs.type != JSONType.array)
        {
            error = "grid config: slotOverrides must be an array";
            return false;
        }
        foreach (ref ov; jsonArray(*ovs))
        {
            if (ov.type != JSONType.object)
            {
                error = "grid config: each slotOverride must be an object";
                return false;
            }
            auto o = jsonObject(ov);
            if ("slot" !in o || o["slot"].type != JSONType.string)
            {
                error = "grid config: slotOverride needs a slot name";
                return false;
            }
            Slot slot;
            if (!parseSlot(o["slot"].str, slot) || slot == Slot.inherit)
            {
                error = "grid config: unknown slot '" ~ o["slot"].str ~ "'";
                return false;
            }
            const i = cast(size_t) slot;
            if (auto fg = "fg" in o)
            {
                Color c;
                if (!readHexColor(fg.str, c, error))
                    return false;
                nextPal.fg[i] = c;
            }
            if (auto bg = "bg" in o)
            {
                Color c;
                if (!readHexColor(bg.str, c, error))
                    return false;
                nextPal.bg[i] = c;
            }
            if (auto a = "fgAlpha" in o)
                nextPal.fgAlpha[i] = cast(ubyte) a.get!long;
            if (auto a = "bgAlpha" in o)
                nextPal.bgAlpha[i] = cast(ubyte) a.get!long;
        }
    }
    cfg = next;
    pal = nextPal;
    return true;
}

/// Serialises `cfg` (no palette) to the same schema `parseGridConfigJson` reads.
string writeGridConfigJson(in GridConfig cfg)
{
    import std.array : appender;
    import std.conv : text;

    auto w = appender!string;
    w ~= "{\n";
    writeSub(w, "minorLattice", cfg.minorLattice, true);
    writeSub(w, "majorLattice", cfg.majorLattice, true);
    writeSub(w, "minorStripes", cfg.minorStripes, true);
    writeSub(w, "majorStripes", cfg.majorStripes, true);
    writeStyle(w, "minorStyle", cfg.minorStyle, true);
    writeStyle(w, "majorStyle", cfg.majorStyle, true);
    writeBrushArr(w, "xBrushes", cfg.brushes.x[0 .. cfg.brushes.xCount], true);
    writeBrushArr(w, "yBrushes", cfg.brushes.y[0 .. cfg.brushes.yCount], false);
    w ~= "}\n";
    return w[];
}

private bool parsePreset(const(char)[] name, out GridPreset p) @safe pure nothrow @nogc
{
    if (name == "defaultLines" || name == "default")
    {
        p = GridPreset.defaultLines;
        return true;
    }
    if (name == "stripeBands" || name == "stripes")
    {
        p = GridPreset.stripeBands;
        return true;
    }
    if (name == "dotPaper" || name == "dots")
    {
        p = GridPreset.dotPaper;
        return true;
    }
    return false;
}

private bool parseVisibility(const(char)[] name, out AxisVisibility v)
    @safe pure nothrow @nogc
{
    if (name == "none" || name == "no")
    {
        v = AxisVisibility.none;
        return true;
    }
    if (name == "x" || name == "X")
    {
        v = AxisVisibility.x;
        return true;
    }
    if (name == "y" || name == "Y")
    {
        v = AxisVisibility.y;
        return true;
    }
    if (name == "xy" || name == "XY")
    {
        v = AxisVisibility.xy;
        return true;
    }
    return false;
}

private bool parseMarkKind(const(char)[] name, out MarkKind k) @safe pure nothrow @nogc
{
    if (name == "lines" || name == "line")
    {
        k = MarkKind.lines;
        return true;
    }
    if (name == "dots" || name == "dot")
    {
        k = MarkKind.dots;
        return true;
    }
    return false;
}

private bool parseSlot(const(char)[] name, out Slot slot) @safe pure nothrow @nogc
{
    switch (name)
    {
        static foreach (m; __traits(allMembers, Slot))
        {
            mixin("case \"" ~ m ~ "\": slot = Slot." ~ m ~ "; return true;");
        }
        default:
            return false;
    }
}

private string slotName(Slot slot) @safe pure nothrow @nogc
{
    final switch (slot)
    {
        static foreach (m; __traits(allMembers, Slot))
        {
            mixin("case Slot." ~ m ~ ": return \"" ~ m ~ "\";");
        }
    }
}

private string visibilityName(AxisVisibility v) @safe pure nothrow @nogc
{
    final switch (v)
    {
        case AxisVisibility.none: return "none";
        case AxisVisibility.x: return "x";
        case AxisVisibility.y: return "y";
        case AxisVisibility.xy: return "xy";
    }
}

private string markKindName(MarkKind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
        case MarkKind.lines: return "lines";
        case MarkKind.dots: return "dots";
    }
}

/// `std.json`'s object/array getters are `@system`; the access itself is the
/// only unsafe step.
private JSONValue[string] jsonObject(JSONValue v) @trusted => v.object;
/// ditto
private JSONValue[] jsonArray(JSONValue v) @trusted => v.array;

private bool readHexColor(const(char)[] s, out Color c, ref string error)
{
    import sparkles.base.term_color : Color, parseHexColor;

    const(char)[] cur = s;
    auto r = parseHexColor(cur);
    if (r.hasError || cur.length != 0)
    {
        error = "grid config: invalid color '" ~ s.idup ~ "'";
        return false;
    }
    c = r.value;
    return true;
}

private bool readSubdivision(T)(
    ref T obj, string key, ref AxisSubdivision dest, ref string error)
{
    import std.json : JSONType;

    auto p = key in obj;
    if (p is null)
        return true;
    if (p.type != JSONType.object)
    {
        error = "grid config: " ~ key ~ " must be an object";
        return false;
    }
    auto o = jsonObject(*p);
    if (auto v = "visibility" in o)
    {
        if (v.type != JSONType.string || !parseVisibility(v.str, dest.visibility))
        {
            error = "grid config: " ~ key ~ ".visibility must be none|x|y|xy";
            return false;
        }
    }
    if (auto i = "interval" in o)
    {
        const n = i.get!long;
        if (n < 1 || n > int.max)
        {
            error = "grid config: " ~ key ~ ".interval must be a positive integer";
            return false;
        }
        dest.interval = cast(int) n;
    }
    return true;
}

private bool readStyle(T)(
    ref T obj, string key, ref LatticeStyle dest, ref string error)
{
    import std.json : JSONType;

    auto p = key in obj;
    if (p is null)
        return true;
    if (p.type != JSONType.object)
    {
        error = "grid config: " ~ key ~ " must be an object";
        return false;
    }
    auto o = jsonObject(*p);
    if (auto m = "markKind" in o)
    {
        if (m.type != JSONType.string || !parseMarkKind(m.str, dest.markKind))
        {
            error = "grid config: " ~ key ~ ".markKind must be lines|dots";
            return false;
        }
    }
    if (auto s = "stroke" in o)
    {
        if (s.type != JSONType.string || !parseSlot(s.str, dest.stroke))
        {
            error = "grid config: " ~ key ~ ".stroke is not a slot name";
            return false;
        }
    }
    if (auto t = "thickness" in o)
    {
        const n = t.get!long;
        if (n < 0 || n > 16)
        {
            error = "grid config: " ~ key ~ ".thickness out of range";
            return false;
        }
        dest.thickness = cast(int) n;
    }
    if (auto d = "dash" in o)
    {
        if (d.type != JSONType.array)
        {
            error = "grid config: " ~ key ~ ".dash must be an array";
            return false;
        }
        auto dash = jsonArray(*d);
        if (dash.length > dashCap)
        {
            error = "grid config: " ~ key ~ ".dash longer than cap";
            return false;
        }
        dest.dashCount = cast(ubyte) dash.length;
        foreach (i, ref e; dash)
        {
            const n = e.get!long;
            if (n < 0 || n > 255)
            {
                error = "grid config: " ~ key ~ ".dash entry out of range";
                return false;
            }
            dest.dash[i] = cast(ubyte) n;
        }
    }
    return true;
}

private bool readBrushes(T)(
    ref T obj, string key, ref StripeBrush[stripeBrushCap] dest, ref ubyte count,
    ref string error)
{
    import std.json : JSONType;

    auto p = key in obj;
    if (p is null)
        return true;
    if (p.type != JSONType.array)
    {
        error = "grid config: " ~ key ~ " must be an array";
        return false;
    }
    auto items = jsonArray(*p);
    if (items.length > stripeBrushCap)
    {
        error = "grid config: " ~ key ~ " longer than cap";
        return false;
    }
    count = cast(ubyte) items.length;
    foreach (i, ref e; items)
    {
        if (e.type != JSONType.string)
        {
            error = "grid config: " ~ key ~ " entries must be strings";
            return false;
        }
        if (e.str == "transparent")
        {
            dest[i] = transparentBrush();
            continue;
        }
        Slot slot;
        if (!parseSlot(e.str, slot))
        {
            error = "grid config: " ~ key ~ " unknown brush '" ~ e.str ~ "'";
            return false;
        }
        dest[i] = slotBrush(slot);
    }
    return true;
}

private void writeSub(W)(ref W w, string key, in AxisSubdivision s, bool comma)
{
    import std.conv : text;

    w ~= `  "`;
    w ~= key;
    w ~= `": {"visibility": "`;
    w ~= visibilityName(s.visibility);
    w ~= `", "interval": `;
    w ~= text(s.interval);
    w ~= comma ? "},\n" : "}\n";
}

private void writeStyle(W)(ref W w, string key, in LatticeStyle s, bool comma)
{
    import std.conv : text;

    w ~= `  "`;
    w ~= key;
    w ~= `": {"markKind": "`;
    w ~= markKindName(s.markKind);
    w ~= `", "stroke": "`;
    w ~= slotName(s.stroke);
    w ~= `", "thickness": `;
    w ~= text(s.thickness);
    w ~= `, "dash": [`;
    foreach (i; 0 .. s.dashCount)
    {
        if (i)
            w ~= ", ";
        w ~= text(s.dash[i]);
    }
    w ~= comma ? "]},\n" : "]}\n";
}

private void writeBrushArr(W)(ref W w, string key, in StripeBrush[] brushes, bool comma)
{
    w ~= `  "`;
    w ~= key;
    w ~= `": [`;
    foreach (i, b; brushes)
    {
        if (i)
            w ~= ", ";
        w ~= '"';
        w ~= b.transparent ? "transparent" : slotName(b.slot);
        w ~= '"';
    }
    w ~= comma ? "],\n" : "]\n";
}

// ── tests ───────────────────────────────────────────────────────────────────

@("grid_backdrop.defaultPresetMatchesRnd4Shape")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    const pal = defaultTwoslashPalette(ColorScheme.dark);
    const fg = RgbColor(0xcc, 0xcc, 0xcc);
    const bg = RgbColor(0x12, 0x12, 0x12);
    GridView view = {
        screen: Rect(0, 0, 40, 16),
        world: Rect(0, 0, 40, 16),
        origin: Point(0, 0),
    };
    SmallBuffer!(DrawOp, 512) ops;
    appendGridBackdrop(ops, GridConfig.init, view, pal, fg, bg);

    size_t rules, fills, glyphs;
    foreach (ref op; ops[])
    {
        if (op.kind == OpKind.rule)
            ++rules;
        else if (op.kind == OpKind.fillRect)
            ++fills;
        else if (op.kind == OpKind.glyph)
            ++glyphs;
    }
    assert(rules > 0, "default lattice emits rules");
    assert(fills == 0, "default has no stripes");
    assert(glyphs == 0, "default is lines, not dots");
}

@("grid_backdrop.dotsAreIntersectionMarks")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    const pal = defaultTwoslashPalette(ColorScheme.dark);
    const fg = RgbColor(0xcc, 0xcc, 0xcc);
    const bg = RgbColor(0x12, 0x12, 0x12);
    auto cfg = gridPreset(GridPreset.dotPaper);
    // Preview: 1:1, hide major so only minor dots every 1 cell.
    cfg.majorLattice.visibility = AxisVisibility.none;
    GridView view = {
        screen: Rect(2, 3, 4, 3),
        world: Rect(0, 0, 4, 3),
        origin: Point(0, 0),
    };
    SmallBuffer!(DrawOp, 64) ops;
    appendGridBackdrop(ops, cfg, view, pal, fg, bg);

    size_t n;
    foreach (ref op; ops[])
    {
        if (op.kind != OpKind.glyph)
            continue;
        ++n;
        assert(op.glyph == '\u00b7');
        assert(op.rect.x >= 2 && op.rect.x < 6);
        assert(op.rect.y >= 3 && op.rect.y < 6);
    }
    // 4 × 3 intersections.
    assert(n == 12, "one dot per visible lattice intersection");
}

@("grid_backdrop.stripesCycleAndSkipTransparent")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    const pal = defaultTwoslashPalette(ColorScheme.dark);
    const fg = RgbColor(0xcc, 0xcc, 0xcc);
    const bg = RgbColor(0x12, 0x12, 0x12);
    auto cfg = gridPreset(GridPreset.stripeBands);
    cfg.minorLattice.visibility = AxisVisibility.none;
    cfg.majorLattice.visibility = AxisVisibility.none;
    GridView view = {
        screen: Rect(0, 0, 16, 16),
        world: Rect(0, 0, 16, 16),
        origin: Point(0, 0),
    };
    SmallBuffer!(DrawOp, 64) ops;
    appendGridBackdrop(ops, cfg, view, pal, fg, bg);

    size_t xWarn, yError, yAnnotate;
    foreach (ref op; ops[])
    {
        if (op.kind != OpKind.fillRect)
            continue;
        if (op.slot == Slot.warn && op.rect.height == 16)
            ++xWarn;
        if (op.slot == Slot.error && op.rect.width == 16)
            ++yError;
        if (op.slot == Slot.annotate && op.rect.width == 16)
            ++yAnnotate;
    }
    // X: [transparent, warn] over 16/8 = 2 bands → one warn fill.
    // Y: [error, annotate, transparent] over 2 bands → error + annotate.
    assert(xWarn == 1);
    assert(yError == 1);
    assert(yAnnotate == 1);
}

@("grid_backdrop.visibilityXOmitsHorizontals")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    const pal = defaultTwoslashPalette(ColorScheme.dark);
    const fg = RgbColor(0xcc, 0xcc, 0xcc);
    const bg = RgbColor(0x12, 0x12, 0x12);
    GridConfig cfg;
    cfg.minorLattice.visibility = AxisVisibility.x;
    cfg.majorLattice.visibility = AxisVisibility.none;
    GridView view = {
        screen: Rect(0, 0, 8, 8),
        world: Rect(0, 0, 8, 8),
        origin: Point(0, 0),
    };
    SmallBuffer!(DrawOp, 64) ops;
    appendGridBackdrop(ops, cfg, view, pal, fg, bg);

    foreach (ref op; ops[])
    {
        if (op.kind != OpKind.rule)
            continue;
        assert(op.ruleEdge == RuleEdge.left, "X-only paints verticals");
    }
    assert(ops.length > 0);
}

@("grid_backdrop.zoomThinsToOneLinePerScreenCell")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    const pal = defaultTwoslashPalette(ColorScheme.dark);
    const fg = RgbColor(0xcc, 0xcc, 0xcc);
    const bg = RgbColor(0x12, 0x12, 0x12);
    GridConfig cfg;
    cfg.majorLattice.visibility = AxisVisibility.none;
    GridView view = {
        screen: Rect(0, 0, 8, 1),
        world: Rect(0, 0, 64, 8),
        origin: Point(0, 0),
        worldPerCell: 8,
        cellsPerWorld: 1,
    };
    SmallBuffer!(DrawOp, 64) ops;
    appendGridBackdrop(ops, cfg, view, pal, fg, bg);

    int[16] xs;
    size_t n;
    foreach (ref op; ops[])
    {
        if (op.kind != OpKind.rule || op.ruleEdge != RuleEdge.left)
            continue;
        assert(n < xs.length);
        xs[n++] = op.rect.x;
    }
    // 8 screen columns, one vertical each, no duplicates.
    assert(n == 8);
    foreach (i; 1 .. n)
        assert(xs[i] > xs[i - 1]);
}

@("grid_backdrop.jsonRoundTripAndPreset")
@safe unittest
{
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    auto cfg = gridPreset(GridPreset.stripeBands);
    const text = writeGridConfigJson(cfg);
    GridConfig back;
    auto pal = defaultTwoslashPalette(ColorScheme.dark);
    string err;
    assert(parseGridConfigJson(text, back, pal, err), err);
    assert(back.majorStripes.visibility == AxisVisibility.xy);
    assert(back.brushes.xCount == 2);
    assert(back.brushes.x[0].transparent);
    assert(back.brushes.x[1].slot == Slot.warn);
    assert(back.brushes.yCount == 3);
    assert(back.brushes.y[1].slot == Slot.annotate);

    GridConfig fromPreset;
    assert(parseGridConfigJson(`{"preset": "dotPaper"}`, fromPreset, pal, err), err);
    assert(fromPreset.minorStyle.markKind == MarkKind.dots);
    assert(fromPreset.majorLattice.interval == 4);

    GridConfig bad;
    assert(!parseGridConfigJson(`{"preset": "hex"}`, bad, pal, err));
    assert(err.length > 0);
}

@("grid_backdrop.slotOverrideChangesPaletteAlpha")
@safe unittest
{
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette;

    auto pal = defaultTwoslashPalette(ColorScheme.dark);
    GridConfig cfg;
    string err;
    assert(parseGridConfigJson(
        `{"slotOverrides":[{"slot":"warn","bgAlpha":51}]}`,
        cfg, pal, err), err);
    assert(pal.bgAlpha[Slot.warn] == 51);
}
