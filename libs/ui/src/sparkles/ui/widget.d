/**
The widget level (WGT) of $(MREF sparkles,ui): a $(LREF Widget) is currently a
tagged record in a flat arena, each container referencing its children by an
explicit index list — not a class hierarchy. `WGT3` / `UI-O2` replace the record
with the required closed sum. The whole tree is one relocatable buffer
($(LREF WidgetTree)), cheap to diff and (later) `SmallBuffer`-back for `@nogc`.

A widget names a semantic $(REF Slot, sparkles,ui,style), $(B never) a concrete
color, keeping presentation out of the tree (the palette resolves slots during
$(MREF sparkles,ui,display_list) construction). Build a tree with $(LREF Builder)
— add each child (getting its index back), then a container over the child-index
list. An explicit list (rather than a contiguous `[first, count)` range) lets a
container's siblings be containers in their own right, whose descendants
interleave in the arena.
*/
module sparkles.ui.widget;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.canvas : LineStyle, RuleEdge;
import sparkles.ui.geometry : Insets, Point, SizeSpec;
import sparkles.ui.style : Decoration, Slot, TextStyle;
import sparkles.ui.wrap : TextWrap;

@safe:

/// Child alignment along one axis of a container (`LAY8`): each child is
/// offset within its allocated band. Distribution effects (`space-between`
/// and friends) are built by inserting `grow` spacer children instead.
enum Alignment : ubyte
{
    start,  /// left / top (the default)
    center, /// centered in the leftover space
    end,    /// right / bottom
}

/// Tri-state visibility (`LAY11`), so chrome can toggle without a layout jump.
enum Visibility : ubyte
{
    visible,   /// laid out and painted (the default)
    hidden,    /// laid out (occupies space) but not painted — CSS `visibility:hidden`
    collapsed, /// removed from flow entirely — CSS `display:none`
}

/// The kind of a $(LREF Widget) node.
enum WidgetKind : ubyte
{
    box,    /// a leaf rectangle (optionally with a slot background)
    text,   /// a text run
    rich,   /// a text run of styled spans (`spans` payload; `WGT6`)
    glyph,  /// a single glyph
    line,   /// a stroked line (connector / underline)
    scrollbar, /// a semantic scrollbar leaf (content units + expansion)
    row,    /// horizontal container (children left→right, `gap` between)
    column, /// vertical container (children top→bottom, `gap` between)
    stack,  /// overlay container (children share the origin; z = order)
    panel,  /// a `box` container with padding + a slot background/border
    popup,  /// a `panel` that floats (shadow, detached from flow)
}

/// One styled span of a $(D WidgetKind.rich) run (`WGT6`) — defined in
/// $(MREF sparkles,ui,wrap) beside its line breaker, re-exported here.
public import sparkles.ui.wrap : TextSpan;

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
    int gap;                         /// inter-child gap (row/column)
    Alignment alignX;                /// children's horizontal alignment (`LAY8`)
    Alignment alignY;                /// children's vertical alignment (`LAY8`)
    Visibility visibility;           /// tri-state visibility (`LAY11`)

    const(char)[] text;      /// `text` payload (borrowed — must outlive the tree)
    TextSpan[] spans;        /// `rich` payload: styled spans of one run
    /// How the `text` run breaks into lines when its allocated width is
    /// narrower than its content (`none` keeps it a single line).
    TextWrap wrap;
    /// Wrapped continuation lines indent by this many cells (a leader's hang —
    /// list items align under their text, not under the bullet).
    int hangIndent;
    dchar glyph;             /// `glyph` payload
    LineStyle lineStyle;     /// `line` stroke style
    Point lineTo;            /// `line` end, relative to the node origin

    // `scrollbar` payload. Its axis is encoded by `barEdge`: left/right/
    // centerX are vertical, top/bottom/centerY horizontal.
    long barContent;
    long barViewport;
    long barOffset;
    RuleEdge barEdge = RuleEdge.right;
    ubyte barExpandPercent;
    bool barTrackLit;
    dchar barTrackGlyph = '│';
    dchar barThumbGlyph = '█';
    RgbColor barTrackFgOverride;
    bool hasBarTrackFgOverride;

    Decoration decoration;   /// box chrome (border/radius/shadow/arrow) — slot-referencing
    TextStyle textStyle;     /// text chrome (font role/size, bold/italic/underline)

    uint[] children;         /// child node indices (empty for leaves)
    size_t hitId;            /// hover/hit id (0 = not hit-testable)
    /// Element identity (`WGT5`; 0 = anonymous): the renderer's per-element
    /// state store is addressed by this key, so scroll offsets, focus and
    /// animation phase survive a rebuild. $(B Identity) decides "is this the
    /// same element" (state carries over); $(B equality) decides "may I skip
    /// repainting" — element state lives in the store, never in this value,
    /// which keeps backend-owned state out of structural equality. Totality and
    /// copy independence still require every payload to satisfy `PRN6`.
    size_t key;

    /// Scroll offset subtracted from every child's origin, in cells (`LAY7`).
    /// The *value* is written by the view; the scroll position it mirrors is
    /// interaction state and lives in a state machine, never in the arena.
    Point childOffset;
    /// Clip painting of the subtree to this node's padded content box, per
    /// axis (`LAY7`) — the display list brackets the children in scissor ops
    /// and culls children that fall fully outside. A clipping container plus
    /// `childOffset` is a viewport.
    bool clipX;
    /// ditto
    bool clipY;

    bool paintBackground;    /// fill `slot`'s background (box/panel/popup)

    /// The theme's syntax channel at node level (the widget twin of
    /// `TextSpan.fg`): $(B resolved) colors that bypass slot resolution, for
    /// document-derived chrome — heading bands, code panels, callout accents —
    /// whose colors come from the content's resolved theme, not the palette.
    /// Each is gated by its flag; `bgOverride` fills only with `paintBackground`.
    RgbColor fgOverride;
    /// ditto
    bool hasFgOverride;
    /// ditto
    RgbColor bgOverride;
    /// ditto
    bool hasBgOverride;
    /// ditto — recolors the `decoration` border
    RgbColor borderOverride;
    /// ditto
    bool hasBorderOverride;
    /// In a `column`, widen to the column's content width (cross-axis stretch —
    /// full-width section dividers); the child's descendants stay left-aligned.
    bool stretch;
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
        bool paintBackground = false, Decoration decoration = Decoration.init)
    {
        return add(Widget(
            kind: kind,
            slot: slot,
            padding: padding,
            gap: gap,
            decoration: decoration,
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
