/**
The layout level (LAY) of $(MREF sparkles,ui): $(LREF layout) turns a
$(REF WidgetTree, sparkles,ui,widget) into a $(LREF Frame) per node — an absolute
$(REF Rect, sparkles,ui,geometry) on the cell grid — in four `O(n)` passes, all
`@safe pure`:

$(NUMBERED_LIST
    * $(B natural width), bottom-up — each node's intrinsic extent with no bound,
    * $(B width allocation), top-down — the parent's content width resolves
        `grow`/`percent`, distributes leftover space and reclaims overflow,
    * $(B height for width), bottom-up — heights measured against the width each
        node was $(I actually allocated) (where wrapping text reports its line
        count), and
    * $(B height allocation + place), top-down — `column` distributes heights
        the way `row` distributed widths, and every node gets its absolute
        origin.
)

Splitting each axis into a measure and an allocation is GTK's
`measure(orientation, for_size)` protocol: the width↔height cycle ("wrapping
needs a width; the width comes from layout") is broken by $(I ordering), not
iteration. Every extent is an integer cell; leftover space is distributed with
`divmod` plus explicit remainder assignment so the parts always sum exactly to
the whole (see `docs/specs/ui/layout.md`, `LAY4`/`LAY6`).

Text is measured through an injected measurer ($(LREF isTextMeasure)); the
default $(LREF CellMeasure) counts one column per codepoint, and a backend passes
its canvas's grapheme-aware measurer instead.
*/
module sparkles.ui.layout;

import sparkles.ui.geometry : cellsOf, Constraints, Insets, Point, Rect, Size, SizeSpec;
import sparkles.ui.widget : Alignment, Visibility, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap, wrapLines;

@safe:

/// A node's resolved position + size, absolute on the cell grid. `layout`
/// returns one `Frame` per arena node, index-parallel to `tree.nodes`.
struct Frame
{
    Rect rect;

    /// For a wrapping text node: the broken lines, as slices of the widget's
    /// `text` — the display list emits one run per line. Empty means the run
    /// is the single unbroken `text` (every non-text node, and `TextWrap.none`).
    const(char)[][] lines;
}

/// The default text measurer: one column per codepoint
/// ($(REF cellsOf, sparkles,ui,geometry)) — the same advance the GUI painter
/// and the HTML `ch` unit use. Cell-grid backends pass their grapheme-aware
/// measurer instead (`LAY5`).
struct CellMeasure
{
    /// The display-column width of `s`.
    int width(scope const(char)[] s) const pure nothrow @nogc
        => cast(int) cellsOf(s);
}

/// The text-measurer capability: `true` iff `T` reports a run's column width.
/// Deliberately unconstrained in attributes — a canvas-backed measurer may be
/// `@system`; the engine's attributes are inferred from the concrete type.
enum bool isTextMeasure(T) = __traits(compiles, (ref T m) {
    int w = m.width("x");
});

static assert(isTextMeasure!CellMeasure);

/// Lays `tree` out within `c`, returning a `Frame` per node. An unbounded axis
/// (`int.max`, the default) sizes the root to its content; a bounded one is the
/// viewport the root resolves against (`fit` clamps, `grow` fills, `percent`
/// takes its share). Text runs are measured through `tm`.
Frame[] layout(TM = CellMeasure)(
    in WidgetTree tree, in Constraints c = Constraints.init, TM tm = TM.init)
if (isTextMeasure!TM)
{
    const n = tree.nodes.length;
    auto natW = new int[](n);   // pass 1: natural widths (bottom-up)
    auto alloW = new int[](n);  // pass 2: allocated widths (top-down)
    auto natH = new int[](n);   // pass 3: heights for allocated width (bottom-up)
    auto frames = new Frame[](n);

    // -- shared helpers ------------------------------------------------------

    // A `collapsed` child is removed from flow (LAY11): zero extent, no gap.
    bool isCollapsed(uint ci)
        => tree.nodes[ci].visibility == Visibility.collapsed;

    // The offset aligning a child within `slack` leftover cells (LAY8).
    static int alignOffset(Alignment a, int slack)
    {
        if (slack <= 0)
            return 0;
        final switch (a) with (Alignment)
        {
            case start: return 0;
            case center: return slack / 2;
            case end: return slack;
        }
    }

    // A child's extent within `avail` cells of parent content, on the axis
    // where no leftover distribution happens (the cross axis, or the root).
    // On a *clipped* axis (`unclampedFit`) a `fit` child keeps its natural
    // extent — overflowing the viewport is the point; painting clips it.
    int resolveAgainst(in SizeSpec spec, int natural, int avail,
        bool unclampedFit = false)
    {
        int v;
        final switch (spec.kind) with (SizeSpec.Kind)
        {
            case fit:
                v = natural <= avail || unclampedFit ? natural : avail;
                break;
            case fixed:
                v = spec.value;
                break;
            case grow:
                v = avail;
                break;
            case percent:
                v = avail * spec.value / 100;
                break;
        }
        return spec.clamp(v);
    }

    // The natural (unbounded) resolution of `spec`: `grow`/`percent` have no
    // extent to take a share of, so their natural size is their content.
    static int resolveNatural(in SizeSpec spec, int content)
    {
        const v = spec.kind == SizeSpec.Kind.fixed ? spec.value : content;
        return spec.clamp(v);
    }

    // The root against one viewport axis: unbounded keeps the natural size.
    int resolveRoot(in SizeSpec spec, int natural, int avail)
        => avail == int.max ? resolveNatural(spec, natural)
            : resolveAgainst(spec, natural, avail);

    // Main-axis distribution (`row` widths / `column` heights): children start
    // from their base extent (`fixed`/`percent` as declared, `fit`/`grow` at
    // natural), leftover space goes to `grow` children by weight — integer
    // divmod, the remaining cells one each to the first growers — and overflow
    // is reclaimed from non-`fixed` children in proportion to their slack above
    // `min`. The parts always sum exactly to the whole while no clamp binds.
    // A clipping container (`noShrink`) skips the reclaim: its content is
    // *meant* to overflow, scrolled by `childOffset` and clipped by paint.
    void distributeMain(
        scope const(uint)[] children, bool horizontal, int avail, int gap,
        scope int[] extents, bool noShrink = false)
    {
        int used;
        int totalWeight;
        bool first = true;

        foreach (k, ci; children)
        {
            if (isCollapsed(ci))
            {
                extents[k] = 0; // out of flow: no extent, no gap
                continue;
            }
            const child = tree.nodes[ci];
            const spec = horizontal ? child.width : child.height;
            const natural = horizontal ? natW[ci] : natH[ci];
            final switch (spec.kind) with (SizeSpec.Kind)
            {
                case fit, grow:
                    extents[k] = spec.clamp(natural);
                    break;
                case fixed:
                    extents[k] = spec.clamp(spec.value);
                    break;
                case percent:
                    extents[k] = spec.clamp(avail * spec.value / 100);
                    break;
            }
            used += extents[k] + (first ? 0 : gap);
            first = false;
            if (spec.kind == SizeSpec.Kind.grow)
                totalWeight += spec.value > 0 ? spec.value : 1;
        }

        if (used < avail && totalWeight > 0)
        {
            // Leftover to the growers: floor share by weight, then the
            // remainder one cell each to the first growers in order.
            const leftover = avail - used;
            int handedOut;
            foreach (k, ci; children)
            {
                const spec = horizontal ? tree.nodes[ci].width : tree.nodes[ci].height;
                if (spec.kind != SizeSpec.Kind.grow || isCollapsed(ci))
                    continue;
                const weight = spec.value > 0 ? spec.value : 1;
                const share = leftover * weight / totalWeight;
                extents[k] = spec.clamp(extents[k] + share);
                handedOut += share;
            }
            int remainder = leftover - handedOut;
            foreach (k, ci; children)
            {
                if (remainder == 0)
                    break;
                const spec = horizontal ? tree.nodes[ci].width : tree.nodes[ci].height;
                if (spec.kind != SizeSpec.Kind.grow || isCollapsed(ci))
                    continue;
                extents[k] = spec.clamp(extents[k] + 1);
                remainder--;
            }
        }
        else if (used > avail && !noShrink)
        {
            // Overflow: reclaim from non-`fixed` children in proportion to
            // their slack above `min` (divmod again; if total slack cannot
            // cover the deficit, the row genuinely overflows and painting
            // clips downstream).
            int deficit = used - avail;
            int totalSlack;
            foreach (k, ci; children)
            {
                const spec = horizontal ? tree.nodes[ci].width : tree.nodes[ci].height;
                if (spec.kind != SizeSpec.Kind.fixed)
                    totalSlack += extents[k] > spec.min ? extents[k] - spec.min : 0;
            }
            if (deficit > totalSlack)
                deficit = totalSlack;
            if (deficit > 0)
            {
                int reclaimed;
                foreach (k, ci; children)
                {
                    const spec = horizontal ? tree.nodes[ci].width : tree.nodes[ci].height;
                    if (spec.kind == SizeSpec.Kind.fixed)
                        continue;
                    const slack = extents[k] > spec.min ? extents[k] - spec.min : 0;
                    const give = deficit * slack / totalSlack;
                    extents[k] -= give;
                    reclaimed += give;
                }
                int remainder = deficit - reclaimed;
                foreach (k, ci; children)
                {
                    if (remainder == 0)
                        break;
                    const spec = horizontal ? tree.nodes[ci].width : tree.nodes[ci].height;
                    if (spec.kind == SizeSpec.Kind.fixed || extents[k] <= spec.min)
                        continue;
                    extents[k]--;
                    remainder--;
                }
            }
        }
    }

    // -- pass 1: natural width, bottom-up -------------------------------------
    // A `Builder` adds children before their container, so a forward walk sees
    // every child measured before the parent that aggregates it.

    int naturalWidth(uint idx)
    {
        const node = tree.nodes[idx];
        int content;
        final switch (node.kind) with (WidgetKind)
        {
            case text:
                content = tm.width(node.text);
                break;
            case glyph:
                content = 1;
                break;
            case line:
                content = absInt(node.lineTo.x);
                break;
            case box:
                break;
            case row:
                bool first = true;
                foreach (ci; node.children)
                {
                    if (isCollapsed(ci))
                        continue;
                    content += natW[ci] + (first ? 0 : node.gap);
                    first = false;
                }
                break;
            case column, stack, panel, popup:
                foreach (ci; node.children)
                    if (!isCollapsed(ci) && natW[ci] > content)
                        content = natW[ci];
                break;
        }
        return resolveNatural(node.width, content + node.padding.horizontal);
    }

    // -- pass 2: width allocation, top-down ------------------------------------

    void allocWidth(uint idx, int allocated)
    {
        alloW[idx] = allocated;
        const node = tree.nodes[idx];
        if (node.children.length == 0)
            return;
        auto content = allocated - node.padding.horizontal;
        if (content < 0)
            content = 0;

        if (node.kind == WidgetKind.row)
        {
            auto widths = new int[](node.children.length);
            distributeMain(node.children, true, content, node.gap, widths,
                node.clipX);
            foreach (k, ci; node.children)
                allocWidth(ci, widths[k]);
        }
        else // column/stack/panel/popup: the cross axis
        {
            foreach (ci; node.children)
            {
                if (isCollapsed(ci))
                {
                    allocWidth(ci, 0);
                    continue;
                }
                const child = tree.nodes[ci];
                auto cw = resolveAgainst(child.width, natW[ci], content,
                    node.clipX);
                // Cross-axis stretch: widen the child's box to the content
                // width (full-width dividers/sections); its own descendants
                // stay start-aligned at their natural widths.
                if (child.stretch && cw < content)
                    cw = content;
                allocWidth(ci, cw);
            }
        }
    }

    // -- pass 3: height for allocated width, bottom-up -------------------------

    int naturalHeight(uint idx)
    {
        const node = tree.nodes[idx];
        int content;
        final switch (node.kind) with (WidgetKind)
        {
            case text:
                if (node.wrap != TextWrap.none)
                {
                    // The cross-axis measure: break against the width this
                    // node was *allocated* (LAY4's forSize), not a guess.
                    auto avail = alloW[idx] - node.padding.horizontal;
                    if (avail < 1)
                        avail = 1;
                    frames[idx].lines = wrapLines(node.text, avail,
                        (scope const(char)[] s) => tm.width(s), node.wrap);
                    content = cast(int) frames[idx].lines.length;
                    if (content < 1)
                        content = 1;
                }
                else
                    content = 1;
                break;
            case glyph:
                content = 1;
                break;
            case line:
                content = node.lineTo.y == 0 ? 1 : absInt(node.lineTo.y);
                break;
            case box:
                break;
            case row:
                foreach (ci; node.children)
                    if (!isCollapsed(ci) && natH[ci] > content)
                        content = natH[ci];
                break;
            case column:
                bool first = true;
                foreach (ci; node.children)
                {
                    if (isCollapsed(ci))
                        continue;
                    content += natH[ci] + (first ? 0 : node.gap);
                    first = false;
                }
                break;
            case stack, panel, popup:
                foreach (ci; node.children)
                    if (!isCollapsed(ci) && natH[ci] > content)
                        content = natH[ci];
                break;
        }
        return resolveNatural(node.height, content + node.padding.vertical);
    }

    // -- pass 4: height allocation + place, top-down ---------------------------

    void place(uint idx, in Point origin, int allocatedH)
    {
        frames[idx].rect = Rect(origin, Size(alloW[idx], allocatedH));
        const node = tree.nodes[idx];
        if (node.children.length == 0)
            return;

        // The scroll offset shifts every child (LAY7); painting clips at this
        // node's content box when it also sets `clipX`/`clipY`.
        const contentX = origin.x + node.padding.left - node.childOffset.x;
        const contentY = origin.y + node.padding.top - node.childOffset.y;
        auto contentW = alloW[idx] - node.padding.horizontal;
        if (contentW < 0)
            contentW = 0;
        auto contentH = allocatedH - node.padding.vertical;
        if (contentH < 0)
            contentH = 0;

        final switch (node.kind) with (WidgetKind)
        {
            case text, glyph, line, box:
                break; // leaves (children.length == 0 already returned)
            case row:
            {
                // Main-axis alignment shifts the whole run in the leftover.
                int used;
                bool first = true;
                foreach (ci; node.children)
                {
                    if (isCollapsed(ci))
                        continue;
                    used += alloW[ci] + (first ? 0 : node.gap);
                    first = false;
                }
                int x = contentX + alignOffset(node.alignX, contentW - used);
                first = true;
                foreach (ci; node.children)
                {
                    if (isCollapsed(ci))
                    {
                        place(ci, Point(contentX, contentY), 0);
                        continue;
                    }
                    if (!first)
                        x += node.gap;
                    first = false;
                    const child = tree.nodes[ci];
                    auto ch = resolveAgainst(child.height, natH[ci], contentH,
                        node.clipY);
                    if (child.stretch && ch < contentH)
                        ch = contentH;
                    place(ci, Point(x,
                        contentY + alignOffset(node.alignY, contentH - ch)), ch);
                    x += alloW[ci];
                }
                break;
            }
            case column:
            {
                auto heights = new int[](node.children.length);
                distributeMain(node.children, false, contentH, node.gap, heights,
                    node.clipY);
                int used;
                bool first = true;
                foreach (k, ci; node.children)
                {
                    if (isCollapsed(ci))
                        continue;
                    used += heights[k] + (first ? 0 : node.gap);
                    first = false;
                }
                int y = contentY + alignOffset(node.alignY, contentH - used);
                first = true;
                foreach (k, ci; node.children)
                {
                    if (isCollapsed(ci))
                    {
                        place(ci, Point(contentX, contentY), 0);
                        continue;
                    }
                    if (!first)
                        y += node.gap;
                    first = false;
                    place(ci, Point(
                        contentX + alignOffset(node.alignX, contentW - alloW[ci]),
                        y), heights[k]);
                    y += heights[k];
                }
                break;
            }
            case stack, panel, popup:
                foreach (ci; node.children)
                {
                    if (isCollapsed(ci))
                    {
                        place(ci, Point(contentX, contentY), 0);
                        continue;
                    }
                    const child = tree.nodes[ci];
                    auto ch = resolveAgainst(child.height, natH[ci], contentH,
                        node.clipY);
                    if (child.stretch && ch < contentH)
                        ch = contentH;
                    place(ci, Point(
                        contentX + alignOffset(node.alignX, contentW - alloW[ci]),
                        contentY + alignOffset(node.alignY, contentH - ch)), ch);
                }
                break;
        }
    }

    // -- run the passes ---------------------------------------------------------

    foreach (i; 0 .. n)
        natW[i] = naturalWidth(cast(uint) i);

    allocWidth(tree.root, resolveRoot(tree.rootNode.width, natW[tree.root], c.maxW));

    foreach (i; 0 .. n)
        natH[i] = naturalHeight(cast(uint) i);

    place(tree.root, Point(0, 0),
        resolveRoot(tree.rootNode.height, natH[tree.root], c.maxH));

    return frames;
}

private int absInt(int v) nothrow @nogc pure => v < 0 ? -v : v;

/**
Serializes a laid-out tree to `w`, one depth-indented line per node — kind,
resolved rectangle, slot, and the payload/flags that explain a layout at a
glance (`LAY12`; the tiling-WM catalog calls an introspectable tree the
highest-leverage layout-debugging investment):

---
column 11×2 @(0,0)
    text 5×1 @(0,0) "short"
    text 11×1 @(0,1) "much longer"
---
*/
void dumpTree(Writer)(ref Writer w, in WidgetTree tree, in Frame[] frames)
{
    import std.conv : to;
    import std.range.primitives : put;
    import sparkles.base.text.writers : writeInteger;
    import sparkles.ui.style : Slot;

    void num(int v)
    {
        if (v < 0)
        {
            put(w, '-');
            v = -v;
        }
        writeInteger(w, cast(uint) v);
    }

    void rec(uint idx, int depth)
    {
        const node = tree.nodes[idx];
        const r = frames[idx].rect;
        foreach (_; 0 .. depth * 4)
            put(w, ' ');
        put(w, node.kind.to!string);
        put(w, ' ');
        num(r.width);
        put(w, '×');
        num(r.height);
        put(w, " @(");
        num(r.x);
        put(w, ',');
        num(r.y);
        put(w, ')');
        if (node.slot != Slot.inherit)
        {
            put(w, " slot=");
            put(w, node.slot.to!string);
        }
        if (node.visibility != Visibility.visible)
        {
            put(w, ' ');
            put(w, node.visibility.to!string);
        }
        if (node.clipX || node.clipY)
        {
            put(w, " clip=");
            if (node.clipX)
                put(w, 'x');
            if (node.clipY)
                put(w, 'y');
        }
        if (frames[idx].lines.length > 1)
        {
            put(w, " lines=");
            writeInteger(w, frames[idx].lines.length);
        }
        if (node.kind == WidgetKind.text)
        {
            put(w, " \"");
            const t = node.text;
            size_t cut = t.length <= 32 ? t.length : 32;
            while (cut < t.length && cut > 0 && (t[cut] & 0xC0) == 0x80)
                cut--; // don't split a codepoint
            put(w, t[0 .. cut]);
            if (cut < t.length)
                put(w, "…");
            put(w, '"');
        }
        put(w, '\n');
        foreach (ci; node.children)
            rec(ci, depth + 1);
    }

    rec(tree.root, 0);
}

/// ditto
string dumpTree(in WidgetTree tree, in Frame[] frames)
{
    import std.array : appender;

    auto w = appender!string;
    dumpTree(w, tree, frames);
    return w[];
}

@("ui.layout.rowFlowWithGap")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // Two text runs in a row with a 1-cell gap.
    auto b = Builder();
    const a0 = b.add(Widget(kind: WidgetKind.text, text: "abc")); // 3×1
    const a1 = b.add(Widget(kind: WidgetKind.text, text: "de"));  // 2×1
    const row = b.container(WidgetKind.row, [a0, a1], gap: 1);
    auto tree = b.finish(row);

    auto frames = layout(tree);
    assert(frames[row].rect == Rect(0, 0, 6, 1)); // 3 + 1 gap + 2
    assert(frames[a0].rect == Rect(0, 0, 3, 1));
    assert(frames[a1].rect == Rect(4, 0, 2, 1));  // after 3 + gap 1
}

@("ui.layout.columnFlowWidestWins")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    auto b = Builder();
    const r0 = b.add(Widget(kind: WidgetKind.text, text: "short"));       // 5×1
    const r1 = b.add(Widget(kind: WidgetKind.text, text: "much longer")); // 11×1
    const col = b.container(WidgetKind.column, [r0, r1]);
    auto tree = b.finish(col);

    auto frames = layout(tree);
    assert(frames[col].rect == Rect(0, 0, 11, 2)); // widest child, stacked heights
    assert(frames[r0].rect == Rect(0, 0, 5, 1));
    assert(frames[r1].rect == Rect(0, 1, 11, 1));  // second row below the first
}

@("ui.layout.columnStretchWidensChild")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // A narrow `stretch` row above a wide row in a column: the narrow one widens to
    // the column's content width (so its border/background spans full-width), while
    // its own descendants stay left-aligned.
    auto b = Builder();
    const narrow = b.add(Widget(kind: WidgetKind.text, text: "ab")); // 2×1
    Widget stretchRow = Widget(kind: WidgetKind.column, children: [narrow], stretch: true);
    const sec = b.add(stretchRow);
    const wide = b.add(Widget(kind: WidgetKind.text, text: "wide content")); // 12×1
    const col = b.container(WidgetKind.column, [sec, wide]);
    auto tree = b.finish(col);

    auto frames = layout(tree);
    assert(frames[col].rect.width == 12);
    assert(frames[sec].rect.width == 12); // stretched from its intrinsic 2 to the column width
    assert(frames[narrow].rect.width == 2); // the descendant keeps its own width, left-aligned
}

@("ui.layout.panelPadding")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.style : Slot;

    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "hello")); // 5×1
    const panel = b.container(WidgetKind.popup, [t],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(panel);

    auto frames = layout(tree);
    // Popup grows by padding on all sides: 5+2 × 1+2.
    assert(frames[panel].rect == Rect(0, 0, 7, 3));
    // Child sits at the padded content origin.
    assert(frames[t].rect == Rect(1, 1, 5, 1));
}

@("ui.layout.growDistributionIsIntegerExact")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // Three equal growers in a 10-cell row: 10 = 3+3+3 with the 1 leftover cell
    // handed to the first grower — 4, 3, 3. The parts always sum to the whole.
    auto b = Builder();
    const g0 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    const g1 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    const g2 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    Widget rowW = Widget(kind: WidgetKind.row, children: [g0, g1, g2],
        width: SizeSpec.fixed(10), height: SizeSpec.fixed(1));
    const row = b.add(rowW);
    auto tree = b.finish(row);

    auto frames = layout(tree);
    assert(frames[g0].rect.width == 4);
    assert(frames[g1].rect.width == 3);
    assert(frames[g2].rect.width == 3);
    assert(frames[g0].rect.x == 0 && frames[g1].rect.x == 4 && frames[g2].rect.x == 7);

    // The exactness property at every width: the parts sum to the whole.
    foreach (w; 1 .. 32)
    {
        auto b2 = Builder();
        const c0 = b2.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow(2)));
        const c1 = b2.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow(3)));
        const c2 = b2.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
        Widget r = Widget(kind: WidgetKind.row, children: [c0, c1, c2],
            width: SizeSpec.fixed(w));
        const ri = b2.add(r);
        auto fr = layout(b2.finish(ri));
        assert(fr[c0].rect.width + fr[c1].rect.width + fr[c2].rect.width == w);
    }
}

@("ui.layout.growSharesLeftoverAfterFixedContent")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // A text label and a grower in a 20-cell row: the grower takes exactly the
    // leftover (20 - 5 - 1 gap = 14).
    auto b = Builder();
    const label = b.add(Widget(kind: WidgetKind.text, text: "hello")); // 5×1
    const fill = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    Widget rowW = Widget(kind: WidgetKind.row, children: [label, fill],
        width: SizeSpec.fixed(20), gap: 1);
    const row = b.add(rowW);
    auto tree = b.finish(row);

    auto frames = layout(tree);
    assert(frames[label].rect == Rect(0, 0, 5, 1));
    assert(frames[fill].rect.x == 6 && frames[fill].rect.width == 14);
}

@("ui.layout.percentOfParentContent")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // percent resolves against the parent's *content* extent (after padding).
    auto b = Builder();
    const half = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.percent(50)));
    Widget colW = Widget(kind: WidgetKind.column, children: [half],
        width: SizeSpec.fixed(22), padding: Insets.symmetric(0, 1));
    const col = b.add(colW);
    auto tree = b.finish(col);

    auto frames = layout(tree);
    assert(frames[col].rect.width == 22);
    assert(frames[half].rect.width == 10); // 50% of 22 - 2 padding = 20
    assert(frames[half].rect.x == 1);      // at the padded content origin
}

@("ui.layout.rootConstraintsBoundFitAndFillGrow")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // A fit column wider than the viewport clamps to it; a grow child fills it.
    auto b = Builder();
    const wide = b.add(Widget(kind: WidgetKind.text,
        text: "this text is much wider than the viewport"));
    const bar = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.grow()));
    const col = b.container(WidgetKind.column, [wide, bar]);
    auto tree = b.finish(col);

    auto frames = layout(tree, Constraints(maxW: 10));
    assert(frames[col].rect.width == 10);  // fit clamped by the viewport
    assert(frames[bar].rect.width == 10);  // grow fills the column's content
    // The overlong text is allocated the content width (clipping is paint's job).
    assert(frames[wide].rect.width == 10);
}

@("ui.layout.overflowShrinksProportionallyToSlack")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // Two fit texts (8 + 6 = 14) in a 10-cell row: the 4-cell deficit is
    // reclaimed in proportion to slack above min — and the parts still sum to
    // the whole. A `min` clamp is honored: a child at min gives nothing more.
    auto b = Builder();
    const t0 = b.add(Widget(kind: WidgetKind.text, text: "eight!!!"));  // 8×1
    Widget keep = Widget(kind: WidgetKind.text, text: "sixsix");        // 6×1
    keep.width.min = 6;                                                 // incompressible
    const t1 = b.add(keep);
    Widget rowW = Widget(kind: WidgetKind.row, children: [t0, t1],
        width: SizeSpec.fixed(10));
    const row = b.add(rowW);
    auto tree = b.finish(row);

    auto frames = layout(tree);
    assert(frames[t1].rect.width == 6);                     // held at min
    assert(frames[t0].rect.width == 4);                     // absorbed the deficit
    assert(frames[t0].rect.width + frames[t1].rect.width == 10);
}

@("ui.layout.wrappingTextReportsItsLineCount")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // A wrapping run in a 10-column viewport: the height-for-width pass breaks
    // it and the frame carries both the line count and the line slices.
    auto b = Builder();
    Widget para = Widget(kind: WidgetKind.text,
        text: "the quick brown fox", wrap: TextWrap.greedy);
    const t = b.add(para);
    const col = b.container(WidgetKind.column, [t]);
    auto tree = b.finish(col);

    auto frames = layout(tree, Constraints(maxW: 10));
    assert(frames[t].lines == ["the quick", "brown fox"]);
    assert(frames[t].rect == Rect(0, 0, 10, 2));  // two rows tall
    assert(frames[col].rect.height == 2);         // the container grew with it

    // Unconstrained, the same tree stays a single line.
    auto loose = layout(tree);
    assert(loose[t].lines == ["the quick brown fox"]);
    assert(loose[t].rect == Rect(0, 0, 19, 1));
}

@("ui.layout.alignmentOffsetsWithinTheBand")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // A 1-cell glyph centered in a 3-row row band, and a short text
    // right-aligned in a 12-cell column.
    auto b = Builder();
    const tall = b.add(Widget(kind: WidgetKind.box,
        width: SizeSpec.fixed(1), height: SizeSpec.fixed(3)));
    const dot = b.add(Widget(kind: WidgetKind.glyph, glyph: '•'));
    Widget rowW = Widget(kind: WidgetKind.row, children: [tall, dot],
        alignY: Alignment.center);
    const row = b.add(rowW);
    auto tree = b.finish(row);

    auto frames = layout(tree);
    assert(frames[row].rect.height == 3);
    assert(frames[dot].rect == Rect(1, 1, 1, 1)); // centered in the 3-row band

    auto b2 = Builder();
    const t = b2.add(Widget(kind: WidgetKind.text, text: "end"));
    Widget colW = Widget(kind: WidgetKind.column, children: [t],
        width: SizeSpec.fixed(12), alignX: Alignment.end);
    const col = b2.add(colW);
    auto fr2 = layout(b2.finish(col));
    assert(fr2[t].rect == Rect(9, 0, 3, 1)); // flush right in 12 cells
}

@("ui.layout.mainAxisAlignmentShiftsTheRun")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // Two 2-cell boxes centered in a 10-cell row: the 4-cell leftover splits
    // around the run (integer floor: offset 2).
    auto b = Builder();
    const c0 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(2)));
    const c1 = b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(2)));
    Widget rowW = Widget(kind: WidgetKind.row, children: [c0, c1],
        width: SizeSpec.fixed(10), gap: 1, alignX: Alignment.center);
    const row = b.add(rowW);
    auto frames = layout(b.finish(row));
    assert(frames[c0].rect.x == 2 && frames[c1].rect.x == 5);
}

@("ui.layout.visibilityTriState")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // hidden keeps its space; collapsed leaves the flow (including its gap).
    auto b = Builder();
    const a0 = b.add(Widget(kind: WidgetKind.text, text: "aa"));
    Widget hid = Widget(kind: WidgetKind.text, text: "bb",
        visibility: Visibility.hidden);
    const a1 = b.add(hid);
    Widget gone = Widget(kind: WidgetKind.text, text: "cc",
        visibility: Visibility.collapsed);
    const a2 = b.add(gone);
    const a3 = b.add(Widget(kind: WidgetKind.text, text: "dd"));
    const row = b.container(WidgetKind.row, [a0, a1, a2, a3], gap: 1);
    auto tree = b.finish(row);

    auto frames = layout(tree);
    // aa | (hidden bb) | dd — the collapsed cc contributes no width and no gap.
    assert(frames[row].rect.width == 8); // 2+1+2+1+2
    assert(frames[a1].rect == Rect(3, 0, 2, 1)); // hidden still occupies space
    assert(frames[a2].rect.size == Size(0, 0));  // collapsed has no extent
    assert(frames[a3].rect.x == 6);

    // The display list paints neither the hidden nor the collapsed run.
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.base.term_color : RgbColor;

    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    assert(ops.length == 2);
    assert(ops[0].text == "aa" && ops[1].text == "dd");
}

@("ui.layout.dumpTreeReadsAtAGlance")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    auto b = Builder();
    const r0 = b.add(Widget(kind: WidgetKind.text, text: "short"));
    const r1 = b.add(Widget(kind: WidgetKind.text, text: "much longer"));
    const col = b.container(WidgetKind.column, [r0, r1]);
    auto tree = b.finish(col);
    auto frames = layout(tree);

    assert(dumpTree(tree, frames) ==
        "column 11×2 @(0,0)\n" ~
        "    text 5×1 @(0,0) \"short\"\n" ~
        "    text 11×1 @(0,1) \"much longer\"\n");
}

@("ui.layout.injectedTextMeasure")
@safe unittest
{
    import sparkles.ui.widget : Builder;

    // A measurer that counts every codepoint double-wide: the engine sizes
    // text with it, proving measurement is injected rather than hardcoded.
    static struct DoubleWide
    {
        int width(scope const(char)[] s) const pure nothrow @nogc
            => cast(int)(cellsOf(s) * 2);
    }

    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "abc"));
    const row = b.container(WidgetKind.row, [t]);
    auto tree = b.finish(row);

    auto frames = layout(tree, Constraints.init, DoubleWide());
    assert(frames[t].rect.width == 6);
    assert(frames[row].rect.width == 6);
}
