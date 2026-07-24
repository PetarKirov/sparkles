/**
The widget level (WGT) of $(MREF sparkles,ui): a $(LREF Widget) is a
$(B tagged-union node in a flat arena), each container referencing its children
by an explicit index list — not a class hierarchy. The whole tree is one
relocatable buffer ($(LREF WidgetTree)), cheap to diff and (later)
`SmallBuffer`-back for `@nogc`.

A widget names a semantic $(REF Slot, sparkles,ui,style), $(B never) a concrete
color, keeping presentation out of the tree (the palette resolves slots during
$(MREF sparkles,ui,display_list) construction). Build a tree with $(LREF Builder)
— add each child (getting its index back), then a container over the child-index
list. An explicit list (rather than a contiguous `[first, count)` range) lets a
container's siblings be containers in their own right, whose descendants
interleave in the arena.
*/
module sparkles.ui.widget;

import sparkles.ui.canvas : LineStyle;
import sparkles.ui.geometry : Insets, Point, SizeSpec;
import sparkles.ui.style : Slot;

@safe:

/// The kind of a $(LREF Widget) node.
enum WidgetKind : ubyte
{
    box,    /// a leaf rectangle (optionally with a slot background)
    text,   /// a text run
    glyph,  /// a single glyph
    line,   /// a stroked line (connector / underline)
    row,    /// horizontal container (children left→right, `gap` between)
    column, /// vertical container (children top→bottom, `gap` between)
    stack,  /// overlay container (children share the origin; z = order)
    panel,  /// a `box` container with padding + a slot background/border
    popup,  /// a `panel` that floats (shadow, detached from flow)
}

/**
One node in the widget arena. All fields default, so DIP1030 named-argument
construction reads declaratively:
---
Widget(kind: WidgetKind.text, text: "title: string", slot: Slot.code)
---
Containers (`row`/`column`/`stack`/`panel`/`popup`) address their children
through the `children` index list; leaves leave it empty.
*/
struct Widget
{
    WidgetKind kind;
    Slot slot = Slot.inherit; /// semantic role (color comes from the palette)

    SizeSpec width = SizeSpec.fit_;  /// horizontal sizing
    SizeSpec height = SizeSpec.fit_; /// vertical sizing
    Insets padding;                  /// inner padding (containers)
    Insets margin;                   /// outer margin
    int gap;                         /// inter-child gap (row/column)

    const(char)[] text;      /// `text` payload (borrowed — must outlive the tree)
    dchar glyph;             /// `glyph` payload
    LineStyle lineStyle;     /// `line` stroke style
    Point lineTo;            /// `line` end, relative to the node origin

    uint[] children;         /// child node indices (empty for leaves)
    size_t hitId;            /// hover/hit id (0 = not hit-testable)
    bool paintBackground;    /// fill `slot`'s background (box/panel/popup)
}

/// A complete widget tree: the arena plus the index of the root node.
struct WidgetTree
{
    Widget[] nodes;
    uint root;

    /// The root node.
    const(Widget) rootNode() const scope pure nothrow @nogc => nodes[root];
}

/**
Accumulates $(LREF Widget)s into an arena. Add each child (keeping its index),
then a container over the child-index list:
---
auto b = Builder();
const sig  = b.add(Widget(kind: WidgetKind.text, text: "title: string", slot: Slot.code));
const docs = b.add(Widget(kind: WidgetKind.text, text: "The title.",     slot: Slot.docs));
const panel = b.container(WidgetKind.popup, [sig, docs],
    slot: Slot.surface, padding: Insets.all(1));
auto tree = b.finish(panel);
---
Uses a GC array in U1 (matching `gui_preview.d`'s `PreviewLine[]`); the node type
is chosen so a later `SmallBuffer!Widget` swap is non-breaking.
*/
struct Builder
{
    Widget[] nodes;

@safe:

    /// Appends `w`; returns its arena index.
    uint add(Widget w)
    {
        nodes ~= w;
        return cast(uint)(nodes.length - 1);
    }

    /// Appends a container over the child nodes named by `children`.
    uint container(WidgetKind kind, uint[] children,
        Slot slot = Slot.inherit, Insets padding = Insets.init, int gap = 0,
        bool paintBackground = false)
    {
        return add(Widget(
            kind: kind,
            slot: slot,
            padding: padding,
            gap: gap,
            children: children,
            paintBackground: paintBackground,
        ));
    }

    /// Freezes the arena into a tree rooted at `root`.
    WidgetTree finish(uint root)
        => WidgetTree(nodes, root);
}

@("ui.widget.builder.childList")
@safe unittest
{
    auto b = Builder();
    const sig = b.add(Widget(kind: WidgetKind.text, text: "title: string", slot: Slot.code));
    const docs = b.add(Widget(kind: WidgetKind.text, text: "The title.", slot: Slot.docs));
    const panel = b.container(WidgetKind.popup, [sig, docs],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(panel);

    assert(tree.nodes.length == 3);
    assert(tree.root == panel);
    assert(tree.rootNode.kind == WidgetKind.popup);
    assert(tree.rootNode.children == [sig, docs]);
    assert(tree.nodes[sig].slot == Slot.code);
    assert(tree.nodes[docs].slot == Slot.docs);
    assert(tree.rootNode.paintBackground);
}
