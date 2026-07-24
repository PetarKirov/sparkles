/**
The layout level (LAY) of $(MREF sparkles,ui): $(LREF layout) turns a
$(REF WidgetTree, sparkles,ui,widget) into a $(LREF Frame) per node — an absolute
$(REF Rect, sparkles,ui,geometry) on the cell grid. Two passes, both `@safe pure`:
a bottom-up $(I measure) (intrinsic size, honoring `fit`/`fixed` + min/max clamps)
and a top-down $(I place) (`row`/`column`/`stack`/`panel`/`popup` box flow with
`gap` and `padding`).

The full flex/grid vocabulary (`grow`/`percent` distribution, wrapping) is the
deferred `LAY2` work; U1 resolves exactly what the twoslash chrome needs — fit
containers with fixed leaves — and treats `grow`/`percent` as `fit`.
*/
module sparkles.ui.layout;

import sparkles.ui.geometry : cellsOf, Constraints, Insets, Point, Rect, Size, SizeSpec;
import sparkles.ui.widget : Widget, WidgetKind, WidgetTree;

@safe:

/// A node's resolved position + size, absolute on the cell grid. `layout`
/// returns one `Frame` per arena node, index-parallel to `tree.nodes`.
struct Frame
{
    Rect rect;
}

/// Lays `tree` out within `c`, returning a `Frame` per node.
Frame[] layout(in WidgetTree tree, in Constraints c = Constraints.init) pure nothrow
{
    // A `Builder` adds children before their container, so a forward walk
    // measures every child before the parent that aggregates it (bottom-up).
    auto sizes = new Size[](tree.nodes.length);
    foreach (i, ref node; tree.nodes)
        sizes[i] = measure(tree, cast(uint) i, sizes);

    auto frames = new Frame[](tree.nodes.length);
    place(tree, tree.root, Point(0, 0), sizes, frames);
    return frames;
}

/// Intrinsic size of node `idx`. Children (lower-indexed in a `Builder` arena)
/// are already measured into `sizes` by the forward walk.
private Size measure(in WidgetTree tree, uint idx, in Size[] sizes) pure nothrow
{
    const node = tree.nodes[idx];

    Size content;
    final switch (node.kind) with (WidgetKind)
    {
        case text:
            content = Size(cast(int) cellsOf(node.text), 1);
            break;
        case glyph:
            content = Size(1, 1);
            break;
        case line:
            content = Size(absInt(node.lineTo.x), node.lineTo.y == 0 ? 1 : absInt(node.lineTo.y));
            break;
        case box:
            content = Size(0, 0);
            break;
        case row:
            foreach (k, ci; node.children)
            {
                const cs = sizes[ci];
                content.w += cs.w + (k ? node.gap : 0);
                if (cs.h > content.h)
                    content.h = cs.h;
            }
            break;
        case column:
            foreach (k, ci; node.children)
            {
                const cs = sizes[ci];
                content.h += cs.h + (k ? node.gap : 0);
                if (cs.w > content.w)
                    content.w = cs.w;
            }
            break;
        case stack, panel, popup:
            foreach (ci; node.children)
            {
                const cs = sizes[ci];
                if (cs.w > content.w)
                    content.w = cs.w;
                if (cs.h > content.h)
                    content.h = cs.h;
            }
            break;
    }

    // Padding grows a container's box; margins are handled by the parent's flow.
    content.w += node.padding.horizontal;
    content.h += node.padding.vertical;

    return Size(
        resolveAxis(node.width, content.w),
        resolveAxis(node.height, content.h),
    );
}

/// Resolves one axis of sizing against the measured content extent. `fit` keeps
/// the content; `fixed` overrides; `grow`/`percent` fall back to `fit` in U1.
/// The spec's min/max always clamp.
private int resolveAxis(in SizeSpec spec, int content) pure nothrow @nogc
{
    int v;
    final switch (spec.kind) with (SizeSpec.Kind)
    {
        case fit, grow, percent:
            v = content;
            break;
        case fixed:
            v = spec.value;
            break;
    }
    return spec.clamp(v);
}

/// Positions node `idx` (and its subtree) with its top-left at `origin`.
private void place(in WidgetTree tree, uint idx, in Point origin,
    in Size[] sizes, Frame[] frames) pure nothrow
{
    const node = tree.nodes[idx];
    const size = sizes[idx];
    frames[idx].rect = Rect(origin.x, origin.y, size.w, size.h);

    const contentX = origin.x + node.padding.left;
    const contentY = origin.y + node.padding.top;

    final switch (node.kind) with (WidgetKind)
    {
        case text, glyph, line, box:
            break; // leaves
        case row:
            int x = contentX;
            foreach (child; node.children)
            {
                place(tree, child, Point(x, contentY), sizes, frames);
                x += sizes[child].w + node.gap;
            }
            break;
        case column:
            int y = contentY;
            foreach (child; node.children)
            {
                place(tree, child, Point(contentX, y), sizes, frames);
                y += sizes[child].h + node.gap;
            }
            break;
        case stack, panel, popup:
            foreach (child; node.children)
                place(tree, child, Point(contentX, contentY), sizes, frames);
            break;
    }
}

private int absInt(int v) nothrow @nogc pure => v < 0 ? -v : v;

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
