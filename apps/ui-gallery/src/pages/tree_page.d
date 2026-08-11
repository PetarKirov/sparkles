/**
The Tree page: the view-model/view split, with the seams visible.

The tree component is the toolkit's exemplar of a three-layer design — data,
interaction, view — and the page is laid out to make the layers legible: the
same `TreeData` is rendered twice, side by side, with $(B different) disclosure
and selection state. Two views of one tree is the property the split exists to
provide, and it is the one thing a renderer that owns its own expansion state
cannot do at all.

Node capabilities are found by introspection: the node type here carries a
`label`, an `icon` and a `slot`, and the renderer picks each up because it is
there. No base class, no interface, no registration.
*/
module pages.tree_page;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.components.tree_view : treeActivate = activate,
    treeCollapseOrUp = collapseOrUp, TreeStep;
import sparkles.ui.components.tree_widget : flatten, FlatTreeRow, Guide,
    TreeData, TreeGlyphs, treeView;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState, TreeDemo;

@safe:

/// ditto
static immutable string[] keys = ["↑ ↓ move", "→ ← open/close", "Enter toggle"];

/**
A node, with three optional capabilities the renderer detects.

`label` is required (a `T` without one must convert to text itself); `icon` and
`slot` are found by `__traits(compiles, …)`. That is the whole extension
mechanism — a filesystem tree and a syntax tree share one renderer without a
type hierarchy between them.
*/
struct Item
{
    string label; ///
    string icon;  ///
    Slot slot = Slot.inherit; ///
}

/// The specimen tree. Shaped so every guide state occurs: a fork, an end, a
/// continuation bar under a non-last child, and a space under a last one.
TreeData!Item sampleTree()
{
    // Directories carry no icon: the renderer already draws a disclosure
    // marker for anything with children, and a second one beside it says the
    // same thing twice. Files carry one, which is what the capability is for.
    TreeData!Item d;
    const src = d.add(Item("src/", "", Slot.chromeAccent));
    const sparkles = d.add(Item("sparkles/", "", Slot.chromeAccent), src);
    d.add(Item("widget.d", "◆ ", Slot.code), sparkles);
    d.add(Item("layout.d", "◆ ", Slot.code), sparkles);
    d.add(Item("theme.d", "◆ ", Slot.code), sparkles);
    d.add(Item("dub.sdl", "▫ ", Slot.docs), src);
    // `components/` is the LAST child of `src/` and has children of its own,
    // which is the only shape that produces a `space` rail: an ancestor with
    // no later siblings draws blank, not a continuation bar. A specimen tree
    // without one would demonstrate three-quarters of the guide model.
    const comps = d.add(Item("components/", "", Slot.chromeAccent), src);
    d.add(Item("chrome.d", "◆ ", Slot.code), comps);
    d.add(Item("tree_widget.d", "◆ ", Slot.code), comps);

    const docs = d.add(Item("docs/", "", Slot.chromeAccent));
    d.add(Item("index.md", "▪ ", Slot.docs), docs);
    d.add(Item("layout.md", "▪ ", Slot.docs), docs);

    d.add(Item("README.md", "▪ ", Slot.docs));
    return d;
}

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const data = sampleTree();
    const d = s.treeDemo;

    // The view flattens fresh (it is pure over the state); the cursor's row
    // index maps to a node through these same rows.
    auto rows = flatten(data, (uint n) => d.open.isOpen(n));
    const selected = d.sel >= 0 && d.sel < cast(long) rows.length
        ? rows[cast(size_t) d.sel].node : uint.max;

    // The second view is the same data under a different opened set — the
    // property the data/interaction split exists to provide.
    auto everything = typeof(d.open).allOpen;
    auto allRows = flatten(data, (uint n) => everything.isOpen(n));

    uint[] body_;
    body_ ~= heading(b, "Tree · data, interaction, view");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The data layer is a flat arena with index links and no interaction "
        ~ "state. The opened set and the selection live beside it, keyed by "
        ~ "node identity. flatten turns the two into visible rows and "
        ~ "precomputes the guide rails, so no renderer re-derives them.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "your view", [
        treeView(b, data, rows, (uint n) => d.open.isOpen(n), selected),
    ]);
    body_ ~= spacer(b);
    body_ ~= section(b, "the same data, everything open", [
        treeView(b, data, allRows, (uint n) => true, uint.max),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the flatten step", [
        kv(b, "nodes", numberText(data.nodes.length), 14, Slot.code),
        kv(b, "visible rows", numberText(rows.length), 14, Slot.code),
        kv(b, "selected", selected < data.nodes.length
            ? data.nodes[selected].value.label : "—", 14, Slot.chromeAccent),
        kv(b, "has children", selected < data.nodes.length
            && data.hasChildren(selected) ? "yes" : "no", 14, Slot.code),
    ]);
    body_ ~= spacer(b);

    body_ ~= section(b, "the four guide states", [
        kv(b, "├─", "this row, with later siblings", 6, Slot.docs),
        kv(b, "└─", "this row, the last sibling", 6, Slot.docs),
        kv(b, "│ ", "an ancestor has later siblings", 6, Slot.docs),
        kv(b, "  ", "an ancestor was a last child", 6, Slot.docs),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "The guides are computed once during flatten, from a per-depth "
        ~ "'has later siblings' accumulator. A renderer that derived them per "
        ~ "frame would be walking to the root on every row.", w);

    return column(b, body_);
}

private string numberText(size_t n)
{
    import std.conv : text;

    return text(n);
}

/// The page's keys, as the shared component's verbs: motions move through the
/// $(B visible) rows, Left is `collapseOrUp`, Enter is `activate`. The page
/// keeps only what the component leaves to an adapter — the rebuild (a fresh
/// flatten of the static specimen) and Right's expand-only meaning.
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    const data = sampleTree();
    void refresh()
    {
        auto open = s.treeDemo.open;
        s.treeDemo.rows = flatten(data, (uint n) => open.isOpen(n));
    }

    refresh();
    if (s.treeDemo.rows.length == 0)
        return false;
    const node = s.treeDemo.selectedNode;

    switch (k.key)
    {
        case Key.down:
            s.treeDemo.moveSel(1);
            return true;
        case Key.up:
            s.treeDemo.moveSel(-1);
            return true;
        case Key.right:
            if (node != uint.max && data.hasChildren(node))
            {
                s.treeDemo.open = s.treeDemo.open.opened(node);
                refresh();
            }
            return true;
        case Key.left:
            if (treeCollapseOrUp(s.treeDemo.tv, data, (uint n) => n)
                == TreeStep.rebuild)
                refresh();
            return true;
        case Key.enter:
            if (node != uint.max && data.hasChildren(node)
                && treeActivate(s.treeDemo.tv, data, (uint n) => n)
                    == TreeStep.rebuild)
                refresh();
            return true;
        default:
            break;
    }

    switch (k.ch)
    {
        // The polarity resets: open everything / close everything, which are
        // O(1) on this machine rather than a walk, because a disclosure state
        // is a default plus a set of exceptions.
        case 'O': s.treeDemo.open = typeof(s.treeDemo.open).allOpen; refresh(); return true;
        case 'C': s.treeDemo.open = typeof(s.treeDemo.open).allClosed; refresh(); return true;
        default: return false;
    }
}

/// ditto — the component mints `node + 1` as a hit id, so a press maps back by
/// subtracting one. Small ids by construction, which is why the shell's own
/// bases start at a thousand.
bool handleActivate(ref GalleryState s, size_t id)
{
    const data = sampleTree();
    if (id == 0 || id > data.nodes.length)
        return false;

    const node = cast(uint)(id - 1);
    if (data.hasChildren(node))
        s.treeDemo.open = s.treeDemo.open.toggled(node);
    auto open = s.treeDemo.open;
    s.treeDemo.rows = flatten(data, (uint n) => open.isOpen(n));
    foreach (i, ref r; s.treeDemo.rows)
        if (r.node == node)
            s.treeDemo.sel = cast(long) i;
    return true;
}

@("ui_gallery.pages.treeSampleProducesEveryGuideState")
@safe unittest
{
    // The page claims the specimen shows all four rails. A tree shaped so that
    // one never occurs would be teaching three-quarters of the model.
    const data = sampleTree();
    auto rows = flatten(data, (uint n) => true);

    bool[Guide.max + 1] seen;
    foreach (ref r; rows)
        foreach (g; r.guides)
            seen[g] = true;

    static foreach (m; __traits(allMembers, Guide))
        assert(seen[__traits(getMember, Guide, m)],
            "the specimen tree never produces Guide." ~ m);
}

@("ui_gallery.pages.treeSelectionMovesThroughVisibleRowsOnly")
@safe unittest
{
    // Pressing down inside a collapsed folder must not land on a hidden node.
    // The bug this rules out is stepping the ARENA index instead of the row.
    GalleryState s;
    const data = sampleTree();

    // Row 0 is src/, closed: the row after it is `docs/` — not `src/`'s own
    // first child, which is not on screen.
    handleKey(s, KeyEvent(Key.down));
    assert(data.nodes[s.treeDemo.selectedNode].value.label == "docs/");

    // Opening it puts the children back in the walk.
    s.treeDemo.sel = 0;
    handleKey(s, KeyEvent(Key.right));
    handleKey(s, KeyEvent(Key.down));
    assert(data.nodes[s.treeDemo.selectedNode].value.label == "sparkles/");
}

@("ui_gallery.pages.treeLeftClosesThenClimbs")
@safe unittest
{
    // The two-step Left every tree view has: close an open node, and from a
    // closed one move to the parent. Doing only the first strands a reader at
    // depth; doing only the second makes closing impossible.
    GalleryState s;
    const data = sampleTree();

    s.treeDemo.open = s.treeDemo.open.opened(0);
    s.treeDemo.sel = 0; // src/
    handleKey(s, KeyEvent(Key.left));
    assert(!s.treeDemo.open.isOpen(0), "an open node closes");
    assert(s.treeDemo.selectedNode == 0, "…and stays selected");

    handleKey(s, KeyEvent(Key.left));
    assert(s.treeDemo.selectedNode == 0, "a root has no parent to climb to");

    // From a child, Left climbs.
    s.treeDemo.open = s.treeDemo.open.opened(0);
    handleKey(s, KeyEvent(Key.down)); // onto sparkles/, closed
    assert(s.treeDemo.selectedNode == 1);
    handleKey(s, KeyEvent(Key.left)); // closed already → climbs
    assert(s.treeDemo.selectedNode == 0, "climbs to the parent");
    assert(data.nodes[1].parent == 0);
}

@("ui_gallery.pages.treePolarityResetsAreWholesale")
@safe unittest
{
    // `allOpen`/`allClosed` are a polarity flip, not an enumeration — which is
    // what makes them O(1) on a tree of any size.
    GalleryState s;
    const data = sampleTree();

    handleKey(s, KeyEvent(Key.char_, 'O'));
    foreach (n; 0 .. data.nodes.length)
        assert(s.treeDemo.open.isOpen(cast(uint) n));
    assert(s.treeDemo.open.exceptions.length == 0, "a reset, not a list");

    handleKey(s, KeyEvent(Key.char_, 'C'));
    foreach (n; 0 .. data.nodes.length)
        assert(!s.treeDemo.open.isOpen(cast(uint) n));
}

@("ui_gallery.pages.treeOneDataTwoIndependentViews")
@safe unittest
{
    // The split's whole justification: the same arena, two opened sets, two
    // different row lists. A renderer owning its expansion state cannot do it.
    const data = sampleTree();
    auto closed = flatten(data, (uint n) => false);
    auto open = flatten(data, (uint n) => true);

    assert(closed.length < open.length);
    assert(open.length == data.nodes.length, "everything open shows every node");
    assert(closed.length == 3, "three roots when nothing is expanded");
}
