/**
The terminal's own surfaces — the exit prompt, toasts, confirmations, the key
guide, pages — as `sparkles:ui` widget trees (docs/specs/terminal/design.md):
built by pure views, laid out by the toolkit, painted through the host's
canvas at a pixel origin, and hit-tested against the same frames they were
painted from, so what a finger or pointer hits is what it sees.

The colours come from the terminal's own scheme: a theme derived from its
foreground and background (D17, `THM7`), so the chrome follows a scheme
change, light or dark, with nothing else to configure.
*/
module chrome;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.geometry : Constraints, Insets, Rect, SizeSpec;
import sparkles.ui.layout : DelegateMeasure, Frame, layout;
import sparkles.ui.state : HoverTarget, hoverTargets;
import sparkles.ui.style : BorderStyle, Decoration, FontRole, Palette, Slot, TextStyle,
    TypeStep;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import settings : ButtonLabels;

/// The chrome's colours, derived from the terminal scheme's (D17).
struct ChromeTheme
{
    Palette palette;
    RgbColor fg = RgbColor(0xcd, 0xd6, 0xf4);
    RgbColor bg = RgbColor(0x1e, 0x1e, 0x2e);
    /// How many rows a button takes to be a touch target (`TOK7`): 1 on the
    /// desktop, as many as 48 dp needs on a phone.
    int targetRows = 1;

    /// The theme for a terminal whose default colours are `fg` on `bg`.
    static ChromeTheme of(RgbColor fg, RgbColor bg) @safe pure nothrow @nogc
    {
        import sparkles.base.term_color : Color;
        import sparkles.ui.theme : Theme;

        return ChromeTheme(Theme(defaultFg: Color.fromRgb(fg), defaultBg: Color.fromRgb(bg))
            .effectivePalette(), fg, bg);
    }

    /// The colour slot `s` fills a surface with (the background when it has
    /// none), for chrome drawn in pixels rather than through a layer.
    RgbColor slotFill(Slot s) const @safe pure nothrow @nogc
    {
        import sparkles.ui.style : resolveSlot;

        const v = resolveSlot(palette, s, fg, bg);
        return v.hasBg ? v.bg : bg;
    }

    /// The colour slot `s` draws text and lines in.
    RgbColor slotInk(Slot s) const @safe pure nothrow @nogc
    {
        import sparkles.ui.style : resolveSlot;

        return resolveSlot(palette, s, fg, bg).fg;
    }
}

/**
The host's text measurer (`GLY10`), published once a frame by a GUI host so
every surface lays out and paints its interface runs in the faces that draw
them. Without one — a test, a cell target — runs measure in cells.
*/
private ChromeMeasure chromeMeasure;
private bool haveChromeMeasure;
private int[6] chromeFaces; // `facesFingerprint` of the published measurer

/// ditto
void useChromeMeasure(ChromeMeasure m) @safe
{
    chromeMeasure = m;
    haveChromeMeasure = true;
    chromeFaces = facesFingerprint();
}

/// The host's measurer, behind delegates so this module names no backend.
alias ChromeMeasure = DelegateMeasure;

/// Lays `tree` out within `c` in the host's faces where it published them.
Frame[] chromeLayout(in WidgetTree tree, in Constraints c) @safe
    => haveChromeMeasure ? layout(tree, c, chromeMeasure) : layout(tree, c);

/// Builds `tree`'s display list into `ops`, measuring as $(LREF chromeLayout) did.
void chromeDisplayList(Ops)(in WidgetTree tree, in Frame[] frames, in Palette palette,
    RgbColor fg, RgbColor bg, ref Ops ops)
{
    import sparkles.ui.display_list : buildDisplayListInto;

    if (haveChromeMeasure)
        buildDisplayListInto(tree, frames, palette, fg, bg, ops, chromeMeasure);
    else
        buildDisplayListInto(tree, frames, palette, fg, bg, ops);
}

/// A surface laid out and placed: what paints it and what hit-tests it.
struct Layer
{
    WidgetTree tree;
    Frame[] frames;
    /// The pixel position of the surface's top-left cell.
    int x, y;
    /// The cell size it was laid out in.
    int cellW = 1, cellH = 1;
    /// The hit rects, in the surface's cells.
    HoverTarget[] hits;
    /// Paint the terminal's background under it first: a page hides the
    /// panes it covers, where a card or a sheet only covers its own boxes.
    bool opaque;
    /// What an opaque layer covers, in pixels, when more than its own extent:
    /// a page narrower than its area (`TPG19`) still hides the panes beside it.
    Rect backdrop;
    /// A panel's own extent, in pixels, when more than its cells: its
    /// surface fills it, and a rule `edgeWidth` wide runs down its right
    /// edge against the panes (`TSS13`).
    Rect panel;
    /// ditto
    int edgeWidth;

    /// Whether anything was built.
    bool empty() const @safe pure nothrow @nogc => frames.length == 0;

    /// The surface's size in cells.
    Rect bounds() const @safe pure nothrow @nogc
        => frames.length ? frames[tree.root].rect : Rect.init;

    /// The surface's extent in pixels.
    Rect pixelBounds() const @safe pure nothrow @nogc
    {
        const b = bounds;
        return Rect(x, y, b.width * cellW, b.height * cellH);
    }

    /// The hit id under pixel (`px`, `py`); 0 for none.
    size_t hitAt(int px, int py) const @safe pure nothrow @nogc
    {
        import sparkles.ui.state : hitAt;

        if (empty || cellW <= 0 || cellH <= 0 || px < x || py < y)
            return 0;
        // In fractional cells: a list scrolled between cells (`LAY7`) is hit
        // where it was painted. Later nodes paint on top: the last one wins.
        return hits.hitAt(cast(float)(px - x) / cellW, cast(float)(py - y) / cellH);
    }

    /// Whether pixel (`px`, `py`) is on the surface (a tap there is the
    /// surface's even where it hits nothing).
    bool contains(int px, int py) const @safe pure nothrow @nogc
    {
        const r = pixelBounds;
        return px >= r.x && px < r.x + r.width && py >= r.y && py < r.y + r.height;
    }
}

/// Where a surface goes within its area.
enum Place : ubyte
{
    top,    /// along the top edge
    bottom, /// along the bottom edge
    center, /// centred
}

/**
Lays `tree` out at most `cols` × `rows` cells and places it in the area whose
top-left pixel is (`x`, `y`): along an edge or centred. `cellW` × `cellH` is
the font's cell.
*/
Layer place(WidgetTree tree, int cols, int rows, int x, int y, int cellW, int cellH,
    Place where = Place.bottom) @safe
{
    Layer l;
    l.tree = tree;
    if (!tree.nodes.length || cols <= 0 || rows <= 0)
        return l;
    placedLayout(tree, cols, rows, l.frames, l.hits);
    l.cellW = cellW > 0 ? cellW : 1;
    l.cellH = cellH > 0 ? cellH : 1;
    const b = l.frames[tree.root].rect;
    final switch (where)
    {
        case Place.top:
            l.x = x;
            l.y = y;
            break;
        case Place.bottom:
            l.x = x;
            l.y = y + (rows - b.height) * l.cellH;
            break;
        case Place.center:
            l.x = x + (cols - b.width) / 2 * l.cellW;
            l.y = y + (rows - b.height) / 2 * l.cellH;
            break;
    }
    return l;
}

// Surfaces are rebuilt on every tick but change only when what they show
// does, and laying one out wraps every run of its text in the host's faces.
// So the last few layouts are kept: the same tree in the same size and the
// same faces reuses its frames and hit rects. The faces are told apart by
// what the measurer answers, since the host republishes it every frame.
private struct Placed
{
    WidgetTree tree;
    int cols, rows;
    int[6] faces;
    Frame[] frames;
    HoverTarget[] hits;
}
private Placed[8] placed;
private size_t placedNext;

/**
$(LREF chromeLayout) at most `cols` × `rows`, through the same cache as
$(LREF place): a surface that measures its own content before placing it
(a scrolled page) reuses the frames of an unchanged tree. The cache keeps
`tree`, so the caller must not mutate its nodes afterwards — copy them first.
*/
Frame[] cachedChromeLayout(WidgetTree tree, int cols, int rows) @safe
{
    Frame[] frames;
    HoverTarget[] hits;
    placedLayout(tree, cols, rows, frames, hits);
    return frames;
}

private void placedLayout(WidgetTree tree, int cols, int rows,
    out Frame[] frames, out HoverTarget[] hits) @safe
{
    const faces = haveChromeMeasure ? chromeFaces : typeof(chromeFaces).init;
    // The same nodes first: a surface that hands back its last tree must not
    // pay a deep comparison against every other one of the same size.
    static foreach (sameNodes; [true, false])
        foreach (ref p; placed)
            if (p.frames.length && p.cols == cols && p.rows == rows && p.faces == faces
                && (sameNodes ? p.tree.nodes is tree.nodes && p.tree.root == tree.root
                    : p.tree == tree))
            {
                frames = p.frames;
                hits = p.hits;
                return;
            }
    frames = chromeLayout(tree, Constraints(maxW: cols, maxH: rows));
    hits = hoverTargets(tree, frames);
    placed[placedNext] = Placed(tree, cols, rows, faces, frames, hits);
    placedNext = (placedNext + 1) % placed.length;
}

// What the measurer answers for each interface role, once per published
// measurer rather than per layout. A style without a role
// measures in cells, which no interface face changes; and a run measures in
// whole cells, so the probe is long enough for a resized face to move it.
private int[6] facesFingerprint() @safe
{
    enum probe = "The quick brown fox jumps over the lazy dog 0123456789";
    int[6] faces;
    if (!haveChromeMeasure)
        return faces;
    static immutable FontRole[3] roles = [FontRole.ui, FontRole.uiMono, FontRole.docs];
    foreach (i, role; roles)
    {
        const st = TextStyle(fontRole: role, typeStep: TypeStep.body);
        faces[2 * i] = chromeMeasure.width(probe, st);
        faces[2 * i + 1] = chromeMeasure.rows(st);
    }
    return faces;
}

@("chrome.place.aResizedInterfaceFaceLaysOutAgain")
@safe unittest
{
    WidgetTree build()
    {
        Builder b;
        const t = b.add(Widget(kind: WidgetKind.text, text: "Settings",
            textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body)));
        return b.finish(b.add(Widget(kind: WidgetKind.column, children: [t])));
    }

    // A host whose interface face draws `perCell` characters a cell.
    static int perCell = 2;
    static int width(scope const(char)[] s, in TextStyle st) @safe
        => st.fontRole == FontRole.ui ? cast(int)(s.length + perCell - 1) / perCell
            : cast(int) s.length;
    static int rows(in TextStyle) @safe => 1;
    import std.functional : toDelegate;

    useChromeMeasure(ChromeMeasure(toDelegate(&width), toDelegate(&rows)));
    scope (exit) haveChromeMeasure = false;

    auto tree = build();
    const first = place(tree, 40, 3, 0, 0, 1, 1, Place.top);
    perCell = 1; // the face grew: the same label takes twice the cells
    useChromeMeasure(ChromeMeasure(toDelegate(&width), toDelegate(&rows)));
    const grown = place(tree, 40, 3, 0, 0, 1, 1, Place.top);
    assert(grown.frames !is first.frames, "a layout measured in the old face is stale");
    const label = first.tree.nodes[first.tree.root].children[0];
    assert(grown.frames[label].rect.width == 2 * first.frames[label].rect.width);
}

@("chrome.place.reusesTheLayoutOfAnUnchangedTree")
@safe unittest
{
    WidgetTree build(string label)
    {
        Builder b;
        const t = b.add(Widget(kind: WidgetKind.text, text: label, slot: Slot.code));
        return b.finish(b.add(Widget(kind: WidgetKind.column, children: [t])));
    }

    const first = place(build("same"), 20, 3, 0, 0, 1, 1, Place.top);
    const again = place(build("same"), 20, 3, 0, 40, 1, 1, Place.top);
    assert(again.frames is first.frames && again.hits is first.hits);
    assert(again.y == 40, "the position is still the caller's");

    const narrower = place(build("same"), 10, 3, 0, 0, 1, 1, Place.top);
    assert(narrower.frames !is first.frames);
    const changed = place(build("other text"), 20, 3, 0, 0, 1, 1, Place.top);
    assert(changed.frames !is first.frames);
    assert(changed.frames[changed.tree.root].rect.width > first.frames[first.tree.root].rect.width);
}

/**
Outline every hit rect in red over the surfaces it belongs to: a debugging
aid that shows where a tap lands next to what is drawn. Set at start-up from
`SPARKLES_DEBUG_HITS` on the desktop or a `debug-hits` file in the app's
files directory on Android.
*/
bool debugHitBoxes;

/// Paints a placed surface through the host's canvas.
void paintLayer(H)(ref H h, in Layer l, in ChromeTheme t) @system
{
    import sparkles.ui.display_list : buildDisplayListInto;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui_app.host : FrameOps;

    if (l.empty)
        return;
    if (l.opaque)
    {
        const r = l.backdrop.width > 0 ? l.backdrop : l.pixelBounds;
        version (TerminalVulkan)
        {
            import sparkles.shaders : v4;
            h.canvas.fillPx(r.x, r.y, r.width, r.height,
                v4(t.bg.r / 255.0f, t.bg.g / 255.0f, t.bg.b / 255.0f, 1));
        }
        else
        {
            import raylib : Color, DrawRectangle;
            DrawRectangle(r.x, r.y, r.width, r.height, Color(t.bg.r, t.bg.g, t.bg.b, 255));
        }
    }
    if (l.panel.width > 0)
    {
        const s = t.slotFill(Slot.surface);
        version (TerminalVulkan)
        {
            import sparkles.shaders : v4;
            h.canvas.fillPx(l.panel.x, l.panel.y, l.panel.width, l.panel.height,
                v4(s.r / 255.0f, s.g / 255.0f, s.b / 255.0f, 1));
        }
        else
        {
            import raylib : Color, DrawRectangle;
            DrawRectangle(l.panel.x, l.panel.y, l.panel.width, l.panel.height,
                Color(s.r, s.g, s.b, 255));
        }
    }
    static FrameOps ops;
    ops.reset();
    chromeDisplayList(l.tree, l.frames, t.palette, t.fg, t.bg, ops);
    auto c = h.canvas;
    static if (__traits(compiles, c.originX = l.x))
    {
        c.originX = l.x;
        c.originY = l.y;
        paint(c, ops[]);
    }
    else
    {
        c.pushOffsetPx(l.x, l.y);
        paint(c, ops[]);
        c.popOffsetPx();
    }
    if (l.panel.width > 0 && l.edgeWidth > 0)
    {
        const e = t.slotInk(Slot.border);
        version (TerminalVulkan)
        {
            import sparkles.shaders : v4;
            h.canvas.fillPx(l.panel.x + l.panel.width - l.edgeWidth, l.panel.y, l.edgeWidth,
                l.panel.height, v4(e.r / 255.0f, e.g / 255.0f, e.b / 255.0f, 1));
        }
        else
        {
            import raylib : Color, DrawRectangle;
            DrawRectangle(l.panel.x + l.panel.width - l.edgeWidth, l.panel.y, l.edgeWidth,
                l.panel.height, Color(e.r, e.g, e.b, 255));
        }
    }
    version (TerminalVulkan) {}
    else
    if (debugHitBoxes)
    {
        import raylib : Color, DrawRectangleLines;

        foreach (ref hit; l.hits)
            DrawRectangleLines(l.x + hit.rect.x * l.cellW, l.y + hit.rect.y * l.cellH,
                hit.rect.width * l.cellW, hit.rect.height * l.cellH, Color(255, 40, 40, 255));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared pieces.
// ─────────────────────────────────────────────────────────────────────────────

/**
A button: its icon and its label as `ui.buttonLabels` says (`TCF9`) — the
label stays the button's accessible name when only the icon shows. `hitId`
makes the whole button a target; `primary` accents it. `minRows` makes it a
touch target (`TOK7`): the embedder asks for as many rows as 48 dp takes.
*/
uint button(ref Builder b, string icon, string label, ButtonLabels mode, size_t hitId,
    bool primary = false, int minRows = 1, int minCols = 0) @safe
{
    // The icon is a symbol, drawn by the cell font, which carries every icon;
    // the caption names an action, in the interface face (`GLY10`).
    const slot = primary ? Slot.accentPrimary : Slot.textPrimary;
    uint[] parts;
    if (mode != ButtonLabels.text && icon.length)
        parts ~= b.add(Widget(kind: WidgetKind.text, text: icon, slot: slot,
            textStyle: TextStyle(bold: primary, fontRole: FontRole.uiMono, typeStep: TypeStep.label)));
    if (mode != ButtonLabels.icon && label.length)
        parts ~= b.add(Widget(kind: WidgetKind.text, text: label, slot: slot,
            textStyle: TextStyle(bold: primary, fontRole: FontRole.ui, typeStep: TypeStep.label)));
    // A lone icon or caption fills the button and centres in it (the canvas
    // places a narrower proportional run by its alignment).
    if (parts.length == 1)
    {
        b.nodes[parts[0]].alignX = Alignment.center;
        b.nodes[parts[0]].width = SizeSpec.grow();
    }
    const content = parts.length == 1 ? parts[0]
        : b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1, alignY: Alignment.center));
    return b.add(Widget(
        kind: WidgetKind.panel,
        children: [content],
        padding: Insets(0, 1, 0, 1),
        // A row too narrow for everything cuts its other content, never a
        // button's caption: an action must say what it does.
        width: SizeSpec(SizeSpec.Kind.fit, 0, minCols, rigid: true),
        // A touch target at least `minRows` tall (`TOK7`: 48 dp on a phone),
        // the button drawn 36 dp tall in it (`TOK11`).
        height: minRows > 1 ? SizeSpec.fixed(minRows) : SizeSpec.fit_,
        alignX: Alignment.center,
        alignY: Alignment.center,
        hitId: hitId,
        slot: Slot.surfaceRaised,
        paintBackground: true,
        decoration: Decoration(borderRadius: 8, drawHeight: 36),
    ));
}

/**
The columns that make a target `rows` tall square on a `cellW` × `cellH` cell:
an icon button as wide as it is tall, as it is drawn.
*/
int squareCols(int rows, int cellW, int cellH) @safe pure nothrow @nogc
    => cellW > 0 ? (rows * cellH + cellW - 1) / cellW : rows;

/// A run of data — a value, a key, an icon — in `slot`, optionally bold: the
/// cell font at the body step (`uiMono`, D64).
uint label(ref Builder b, const(char)[] text, Slot slot = Slot.textPrimary,
    bool bold = false) @safe
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot,
        textStyle: TextStyle(bold: bold, fontRole: FontRole.uiMono, typeStep: TypeStep.body)));

/**
`text` in the interface face (design-system `GLY10`): a name, a description, a
sentence — what is read as words. A value, a key chord or a log line stays a
$(LREF label), in the cell font, where it is compared character by character.
*/
uint uiLabel(ref Builder b, const(char)[] text, Slot slot = Slot.textPrimary,
    bool bold = false, TypeStep step = TypeStep.body) @safe
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot,
        textStyle: TextStyle(bold: bold, fontRole: FontRole.ui, typeStep: step)));

/// A row of `children`, `gap` cells apart.
uint row(ref Builder b, uint[] children, int gap = 1) @safe
    => b.add(Widget(kind: WidgetKind.row, children: children, gap: gap));

/// A column of `children`.
uint column(ref Builder b, uint[] children, int gap = 0) @safe
    => b.add(Widget(kind: WidgetKind.column, children: children, gap: gap));

/// A full-width band in the raised surface, padded, holding `children` in a
/// column — the body of a banner, a sheet or a card.
uint band(ref Builder b, uint[] children, bool fullWidth = true) @safe
    => b.add(Widget(
        kind: WidgetKind.panel,
        // The column fills the band, so a full-width row in a sheet is a
        // target across the whole sheet, not only under its text.
        children: [b.add(Widget(kind: WidgetKind.column, children: children,
            width: fullWidth ? SizeSpec.grow() : SizeSpec.fit_))],
        padding: Insets(0, 1, 0, 1),
        width: fullWidth ? SizeSpec.grow() : SizeSpec.fit_,
        slot: Slot.surface,
        paintBackground: true,
        decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets(1, 0, 0, 0)),
    ));

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("chrome.place.hitsLandWhereTheButtonsPaint")
@safe unittest
{
    Builder b;
    const a = button(b, "↻", "Re-run", ButtonLabels.iconText, 7);
    const c = button(b, "×", "Close", ButtonLabels.iconText, 9);
    const root = band(b, [row(b, [a, c])]);
    const l = place(b.finish(root), 40, 10, 100, 200, 10, 20, Place.bottom);
    assert(!l.empty);
    // Bottom-placed: the band's last row is the area's last row.
    assert(l.y + l.bounds.height * 20 == 200 + 10 * 20);
    // The first button starts one cell in (the band's padding), the second
    // after it and a gap.
    assert(l.bounds.height == 1);
    assert(l.hitAt(100 + 1 * 10 + 2, l.y + 5) == 7);
    assert(l.hitAt(100 + 12 * 10 + 2, l.y + 5) == 9);
    assert(l.hitAt(100 + 39 * 10, l.y + 5) == 0, "the band itself is no button");
    assert(l.contains(100 + 39 * 10, l.y + 5));
}

@("chrome.button.labelsFollowTheSetting")
@safe unittest
{
    import sparkles.ui.state : HoverTarget;

    foreach (mode, want; [ButtonLabels.iconText: 8, ButtonLabels.text: 6, ButtonLabels.icon: 1])
    {
        Builder b;
        const root = button(b, "↻", "Re-run", mode, 1);
        const l = place(b.finish(root), 40, 4, 0, 0, 1, 1, Place.top);
        assert(l.bounds.width == want + 2, "padding of one cell each side");
    }
}

@("chrome.ChromeTheme.derivesFromTheScheme")
@safe unittest
{
    const dark = ChromeTheme.of(RgbColor(0xcd, 0xd6, 0xf4), RgbColor(0x1e, 0x1e, 0x2e));
    const light = ChromeTheme.of(RgbColor(0x4c, 0x4f, 0x69), RgbColor(0xef, 0xf1, 0xf5));
    assert(dark.palette.bg[Slot.surface] != light.palette.bg[Slot.surface]);
}

@("chrome.squareCols.coversTheTargetsHeight")
@safe pure nothrow @nogc unittest
{
    // A phone's 3-row target on a 25 × 47 px cell: 141 px tall, so 6 columns.
    assert(squareCols(3, 25, 47) == 6);
    assert(squareCols(1, 1, 1) == 1, "a cell target: one column a row");
    assert(squareCols(2, 0, 10) == 2, "no cell size: fall back to the rows");
}
