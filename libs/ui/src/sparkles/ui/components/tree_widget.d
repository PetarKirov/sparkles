/**
The tree component (`WGT12`, `VMD1`–`VMD6`) — the $(B exemplar) of the
view-model/view split, built to the tree-view case study's three-layer design:

$(LIST
    * $(B data) ($(LREF TreeData)) — a flat node arena with parent/child/sibling
        index links. No interaction state, no decoration: copying the tree is
        one array duplication, so it is a value.
    * $(B interaction) — an opened set ($(REF DisclosureState,
        sparkles,ui,state)), a selection, a scroll offset — lives $(B beside)
        the data, keyed by identity, so one tree can back several independent
        views.
    * $(B view) ($(LREF treeView)) — a pure function from both to a widget
        subtree; owns glyphs and slots only.
)

$(LREF flatten) — hierarchy to the visible rows — is a $(B pure free function)
with no lazy loading and no filtering mixed in (the case study names mixing
them as the failure mode), and it precomputes the four-state guide model
(space / continue / fork / end) per depth level, so no renderer re-derives
rails per frame.
*/
module sparkles.ui.components.tree_widget;

import sparkles.ui.state : DisclosureState;
import sparkles.base.term_color : RgbColor;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;

@safe:

/**
The data layer (`VMD1`): a flat arena of `T` values with index links. `add`
appends under a parent (or as a root), maintaining sibling chains; there is no
remove — rebuild instead (flat storage is what makes per-keystroke rebuilding
viable, per the case study's tree-as-search-result mode).
*/
struct TreeData(T)
{
    /// One node: the value plus its structural links (`uint.max` = none).
    static struct Node
    {
        T value;
        uint parent = uint.max;
        uint firstChild = uint.max;
        uint nextSibling = uint.max;
    }

    Node[] nodes;
    uint firstRoot = uint.max;

    /// Appends `value` under `parent` (`uint.max` = a new root); returns its index.
    uint add(T value, uint parent = uint.max) pure nothrow
    {
        const idx = cast(uint) nodes.length;
        nodes ~= Node(value, parent);
        auto head = parent == uint.max ? &firstRoot : &nodes[parent].firstChild;
        if (*head == uint.max)
            *head = idx;
        else
        {
            auto at = *head;
            while (nodes[at].nextSibling != uint.max)
                at = nodes[at].nextSibling;
            nodes[at].nextSibling = idx;
        }
        return idx;
    }

    /// `true` iff `idx` has at least one child.
    bool hasChildren(uint idx) const pure nothrow @nogc
        => nodes[idx].firstChild != uint.max;
}

/// The four-state guide model (`VMD4`): what to draw at one depth level of a row.
enum Guide : ubyte
{
    space,       /// an ancestor was a last child — nothing to draw
    continueBar, /// an ancestor has later siblings — `│`
    fork,        /// this row, with later siblings — `├`
    end,         /// this row, the last sibling — `└`
}

/// One visible row of a flattened tree: the node, its depth, and the guide
/// column per depth level (`guides.length == depth + 1`; the last entry is the
/// row's own fork/end).
struct FlatTreeRow
{
    uint node;
    int depth;
    Guide[] guides;
}

/**
The flatten step (`VMD3`): hierarchy → the visible rows, honoring `isOpen`
(closed nodes keep their subtree out). Pure and free — no lazy loading, no
filtering — and the guides are computed here, once, from a per-depth
"has later siblings" accumulator (broot's precomputed rails).
*/
FlatTreeRow[] flatten(T)(in TreeData!T data, scope bool delegate(uint) @safe isOpen)
{
    FlatTreeRow[] rows;
    Guide[] rails; // per ancestor depth: space or continueBar

    void walk(uint idx, int depth)
    {
        for (auto at = idx; at != uint.max; at = data.nodes[at].nextSibling)
        {
            const last = data.nodes[at].nextSibling == uint.max;
            auto guides = rails[0 .. depth].dup;
            guides ~= last ? Guide.end : Guide.fork;
            rows ~= FlatTreeRow(at, depth, guides);
            if (data.hasChildren(at) && isOpen(at))
            {
                if (rails.length <= depth)
                    rails.length = depth + 1;
                rails[depth] = last ? Guide.space : Guide.continueBar;
                walk(data.nodes[at].firstChild, depth + 1);
            }
        }
    }

    walk(data.firstRoot, 0);
    return rows;
}

/// The tree's charset — theme-glyph data with unicode defaults. All guide
/// cells are three columns wide, with one space between the connector and
/// the row's content. An adapter whose icons already express disclosure
/// (the explorer's open/closed folder) passes empty marker strings.
struct TreeGlyphs
{
    string fork = "├─ ";
    string end = "└─ ";
    string continueBar = "│  ";
    string space = "   ";
    string closed = "▸ "; /// disclosure marker: children, not shown
    string open = "▾ ";   /// disclosure marker: children, shown
    string leaf = "";     /// no children
}

/**
The view (`WGT12`): rows → a widget column. Owns only glyphs and slots — the
guides take the `gutter` slot, the selected row the `selection` tint, a row's
label its node's own text. Node capabilities are detected by introspection
(`VMD6`): a `T` exposing `label` renders it (else `T` itself must convert to
text); an optional `icon` renders before the label; an optional `slot`
overrides the label slot — so a filesystem tree and a syntax tree share this
one renderer with no type hierarchy.
*/
uint treeView(T)(ref Builder b, in TreeData!T data, in FlatTreeRow[] rows,
    scope bool delegate(uint) @safe isOpen,
    uint selected = uint.max, TreeGlyphs glyphs = TreeGlyphs.init,
    RgbColor selectionBg = RgbColor.init, bool hasSelectionBg = false)
{
    static const(char)[] labelOf(ref const T v)
    {
        static if (__traits(compiles, { const(char)[] s = v.label; }))
            return v.label;
        else
            return v;
    }

    auto rowIds = new uint[](rows.length);
    foreach (i, ref row; rows)
    {
        TextSpan[] spans;
        foreach (d, g; row.guides)
        {
            const isOwn = d + 1 == row.guides.length;
            final switch (g) with (Guide)
            {
                case space: spans ~= TextSpan(glyphs.space, Slot.gutter); break;
                case continueBar: spans ~= TextSpan(glyphs.continueBar, Slot.gutter); break;
                case fork: spans ~= TextSpan(glyphs.fork, Slot.gutter); break;
                case end: spans ~= TextSpan(glyphs.end, Slot.gutter); break;
            }
        }
        const node = row.node;
        spans ~= TextSpan(data.hasChildren(node)
            ? (isOpen(node) ? glyphs.open : glyphs.closed) : glyphs.leaf,
            Slot.gutter);

        ref const v = data.nodes[node].value;
        static if (__traits(compiles, { const(char)[] s = v.icon; }))
            if (v.icon.length)
            {
                auto ic = TextSpan(v.icon, Slot.info);
                // Optional per-node icon color (VMD6): a file-type brand hue
                // rides the resolved-color channel, bypassing the slot.
                static if (__traits(compiles,
                    { bool b = v.hasIconFg; ic.fg = v.iconFg; }))
                    if (v.hasIconFg)
                    {
                        ic.fg = v.iconFg;
                        ic.hasFg = true;
                    }
                spans ~= ic;
            }
        Slot labelSlot = Slot.inherit;
        static if (__traits(compiles, { Slot s = v.slot; }))
            labelSlot = v.slot;

        auto lbl = TextSpan(labelOf(v), labelSlot);
        // Optional per-node label color (VMD6) — e.g. the open document's
        // theme accent — riding the resolved-color channel.
        static if (__traits(compiles, { bool b2 = v.hasLabelFg; lbl.fg = v.labelFg; }))
            if (v.hasLabelFg)
            {
                lbl.fg = v.labelFg;
                lbl.hasFg = true;
            }
        spans ~= lbl;

        Widget w = Widget(kind: WidgetKind.rich, spans: spans,
            hitId: node + 1, // hit identity = node index + 1 (0 = none)
            paintBackground: node == selected, stretch: node == selected,
            slot: node == selected ? Slot.selection : Slot.inherit);
        // A resolved (theme-derived) selection tint overrides the palette slot.
        if (node == selected && hasSelectionBg)
        {
            w.bgOverride = selectionBg;
            w.hasBgOverride = true;
        }
        rowIds[i] = b.add(w);
    }
    return b.container(WidgetKind.column, rowIds);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.ui.state : DisclosureState;

    // A tiny labelled tree:
    //   src
    //   ├─ app.d
    //   └─ ui
    //      ├─ widget.d
    //      └─ layout.d
    //   docs
    private TreeData!string sample() @safe pure nothrow
    {
        TreeData!string t;
        const src = t.add("src");
        t.add("app.d", src);
        const ui = t.add("ui", src);
        t.add("widget.d", ui);
        t.add("layout.d", ui);
        t.add("docs");
        return t;
    }
}

@("ui.tree_widget.flattenHonorsDisclosure")
@safe unittest
{
    auto t = sample();

    // All open: every node visible, in depth-first order.
    auto all = flatten(t, (uint) => true);
    assert(all.length == 6);
    assert(all[0].depth == 0 && all[1].depth == 1 && all[3].depth == 2);

    // Close "ui" (index 2): its two children disappear; nothing else moves.
    auto opened = DisclosureState!uint.allOpen.closed(2);
    auto some = flatten(t, (uint n) => opened.isOpen(n));
    assert(some.length == 4);
    foreach (ref row; some)
        assert(row.depth < 2); // widget.d / layout.d are gone

    // The data layer holds no view state: the tree is unchanged by all this.
    assert(t.nodes.length == 6);
}

@("ui.tree_widget.guidesFollowTheFourStateModel")
@safe unittest
{
    auto t = sample();
    auto rows = flatten(t, (uint) => true);

    // src (has a later sibling) forks; docs (last root) ends.
    assert(rows[0].guides == [Guide.fork]);
    assert(rows[5].guides == [Guide.end]);
    // app.d sits under a continuing ancestor rail (src has a later sibling).
    assert(rows[1].guides == [Guide.continueBar, Guide.fork]);
    // layout.d: src's rail continues (docs follows src), ui's rail is a space
    // (ui is src's last child), and the row itself is its parent's last — end.
    assert(rows[4].guides == [Guide.continueBar, Guide.space, Guide.end]);
}

@("ui.tree_widget.viewRendersGuidesMarkersAndSelection")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    auto t = sample();
    auto rows = flatten(t, (uint) => true);
    auto b = Builder();
    const tree = treeView(b, t, rows, (uint) => true, selected: 2);
    auto wt = b.finish(tree);

    auto ops = buildDisplayList(wt, layout(wt), defaultTwoslashPalette(),
        RgbColor(0xff, 0xff, 0xff), RgbColor(0, 0, 0));

    bool sawOpenMarker, sawEndGuide, sawSelection;
    foreach (ref op; ops)
    {
        if (op.kind == OpKind.textRun && op.text == "▾ ")
            sawOpenMarker = true;
        if (op.kind == OpKind.textRun && op.text == "└─ ")
            sawEndGuide = true;
        if (op.kind == OpKind.fillRect && op.slot == Slot.selection)
            sawSelection = true;
    }
    assert(sawOpenMarker && sawEndGuide && sawSelection);

    // A theme-derived selection tint overrides the palette slot; empty marker
    // strings suppress the disclosure column (icon-as-disclosure adapters).
    auto b2 = Builder();
    const t2 = treeView(b2, t, rows, (uint) => true, selected: 2,
        TreeGlyphs(closed: "", open: "", leaf: ""),
        RgbColor(0x20, 0x30, 0x40), hasSelectionBg: true);
    auto wt2 = b2.finish(t2);
    auto ops2 = buildDisplayList(wt2, layout(wt2), defaultTwoslashPalette(),
        RgbColor(0xff, 0xff, 0xff), RgbColor(0, 0, 0));
    bool sawThemedSel, sawMarker2;
    foreach (ref op; ops2)
    {
        if (op.kind == OpKind.fillRect && op.visual.bg == RgbColor(0x20, 0x30, 0x40))
            sawThemedSel = true;
        if (op.kind == OpKind.textRun && (op.text == "▾ " || op.text == "▸ "))
            sawMarker2 = true;
    }
    assert(sawThemedSel && !sawMarker2);
}

@("ui.tree_widget.capabilitiesByIntrospection")
@safe unittest
{
    // A richer node type: label + icon + slot, no inheritance anywhere (VMD6).
    static struct FileNode
    {
        string label;
        string icon;
        Slot slot;
    }

    TreeData!FileNode t;
    t.add(FileNode("README.md", " ", Slot.info));

    auto rows = flatten(t, (uint) => true);
    auto b = Builder();
    const tree = treeView(b, t, rows, (uint) => true);
    auto wt = b.finish(tree);

    // The row's spans carry icon + label with the node's own slot.
    const spans = wt.nodes[wt.nodes[tree].children[0]].spans;
    assert(spans[$ - 2].text == " " && spans[$ - 2].slot == Slot.info);
    assert(spans[$ - 1].text == "README.md" && spans[$ - 1].slot == Slot.info);
}
