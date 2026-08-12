/**
The inspector panel: the toolkit looking at itself, beside whatever it shows.

The panel mounts the generic inspector component
($(MREF sparkles,ui,components,inspector)) over the showing page's own widget
tree — the `inspectWidgets` adapter, so the catalog dogfoods the component it
catalogs. Rows are collapsible (click a container to fold its subtree), a
click selects a node and the details pane answers for it (kind, resolved
rect, text, key, hit id, slot) from the $(B same) frames the page painted
with.

It used to be a $(B page), dumping the previously viewed one — which meant the
subject was never on screen while its dump was. As a shell panel toggled with
`|` it sits beside the showing page and inspects $(I that), live: move to
another page, press a knob, resize — the tree follows. A panel cannot inspect
itself into recursion the way a page could: it is not in the catalog, so no
`view` here ever calls back into it.
*/
module inspector;

import std.conv : text;

import sparkles.ui.components.inspector : DetailRow, inspectorView,
    inspectWidgets, WidgetInspect;
import sparkles.ui.components.tree_view : treeActivate = activate, TreeStep,
    TreeViewState;
import sparkles.ui.components.tree_widget : flatten;
import sparkles.ui.geometry : Constraints;
import sparkles.ui.layout : layout;
import sparkles.ui.widget : Builder, WidgetTree;

import registry : pages;
import scrollbars : gutterCells;
import state : GalleryState;

@safe:

/// The panel tree's hit-id base — far above the shell's chrome bases and any
/// page's own ids, so a widget tree of any size cannot collide.
enum uint hitInspTree = 100_000;

/// The width the panel's rows are built at: the dock-arranged column less its
/// own horizontal padding and the bar's gutter. Fixed rather than `grow`,
/// because the body lives inside a scroll viewport, where `grow` collapses to
/// natural width (the caught defect the spec's ledger records) — and read from
/// the state, because the panel's divider is draggable.
int inspectorInnerWidth(in GalleryState s) pure nothrow @nogc
    => s.inspCols - 2 - gutterCells;

/// The showing page, rebuilt in its own builder and laid out at the width
/// the content pane actually has — so the inspection describes the frame on
/// screen, not a hypothetical one. The rebuild is what pages being pure
/// views over the state buys: calling `view` twice a frame doubles nothing,
/// because a page owns nothing to double.
private WidgetInspect inspectShowing(in GalleryState s,
    out WidgetTree subjectTree, out size_t frameCount) @safe
{
    const subject = pages[s.page];
    auto sb = Builder();
    subjectTree = sb.finish(subject.view(sb, s));
    auto frames = layout(subjectTree, Constraints(maxW: s.contentWidth));
    frameCount = frames.length;
    return inspectWidgets(subjectTree, frames);
}

/// The panel's body: the component over the showing page's tree.
uint inspectorBody(ref Builder b, in GalleryState s)
{
    WidgetTree subjectTree;
    size_t frames;
    auto wi = inspectShowing(s, subjectTree, frames);

    // The panel's tree state, made concrete for this frame: the persistent
    // pieces (disclosure, selection) from the state, rows from the current
    // disclosure, the window covering every row (the panel's own scroll
    // viewport does the scrolling).
    TreeViewState!uint tv;
    tv.open = typeof(tv.open)(s.insp.open.defaultOpen,
        s.insp.open.exceptions.dup);
    tv.sel = s.insp.sel;
    const open = tv.open;
    tv.rows = flatten(wi.data, (uint n) => open.isOpen(n));
    tv.chromeRows = 0;
    tv.headerRows = 0;
    tv.width = inspectorInnerWidth(s);
    tv.height = cast(int) tv.rows.length;
    // The gallery shell owns this panel's scroll gutter; the nested tree is
    // deliberately chromeless and must not reserve a second one.
    tv.scrollGutterV = 0;
    tv.scrollGutterH = 0;

    const selNode = tv.selectedNode;
    auto details = wi.details(selNode);
    if (selNode == uint.max)
        details = [
            DetailRow("page", pages[s.page].title),
            DetailRow("laid out at", text(s.contentWidth, " cells wide")),
            DetailRow("nodes", text(subjectTree.nodes.length)),
        ];

    return inspectorView(b, wi.data, tv, (uint n) => open.isOpen(n),
        text("inspector · ", pages[s.page].title), null, details,
        inspectorInnerWidth(s), hitBase: hitInspTree);
}

/// A completed press on a panel row: select it; a container also toggles its
/// subtree. Returns false for ids that are not the panel's.
bool inspectorActivate(ref GalleryState s, size_t id) @safe
{
    if (id < hitInspTree)
        return false;

    WidgetTree subjectTree;
    size_t frames;
    auto wi = inspectShowing(s, subjectTree, frames);
    const node = cast(uint)(id - hitInspTree);
    if (node >= wi.data.nodes.length)
        return false;

    auto open = s.insp.open;
    s.insp.rows = flatten(wi.data, (uint n) => open.isOpen(n));
    foreach (i, ref const r; s.insp.rows)
        if (r.node == node)
            s.insp.sel = cast(long) i;
    if (treeActivate(s.insp, wi.data, (uint n) => n) == TreeStep.rebuild)
    {
        auto open2 = s.insp.open;
        s.insp.rows = flatten(wi.data, (uint n) => open2.isOpen(n));
    }
    return true;
}

@("ui_gallery.inspector.namesAndMirrorsTheShowingPage")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import registry : pageIndexOf;

    // The panel names and inspects the page beside it — the question the old
    // last-page inspector could never answer while its subject was hidden.
    GalleryState s;
    s.page = pageIndexOf("primitives");

    auto b = Builder();
    auto tree = b.finish(inspectorBody(b, s));

    bool named;
    foreach (ref n; tree.nodes)
        foreach (ref sp; n.spans)
            named |= sp.text.canFind("Primitives");
    assert(named, "the panel names its subject");
}

@("ui_gallery.inspector.treeMirrorsTheEngine")
@safe unittest
{
    import sparkles.ui.layout : dumpTree;
    import std.algorithm : count, splitter;
    import registry : pageIndexOf;

    // The panel's tree has one row per subject node (everything open), and
    // the engine's own dump agrees on the count — a panel disagreeing with
    // the tree beneath it would be worse than no panel.
    GalleryState s;
    s.page = pageIndexOf("layout");

    WidgetTree subjectTree;
    size_t frames;
    auto wi = inspectShowing(s, subjectTree, frames);
    auto rows = flatten(wi.data, (uint) => true);
    assert(rows.length == subjectTree.nodes.length);

    auto sb = Builder();
    auto subject2 = sb.finish(pages[s.page].view(sb, s));
    auto lay = layout(subject2, Constraints(maxW: s.contentWidth));
    // `dumpTree` writes one line per node plus a trailing newline.
    assert(dumpTree(subject2, lay).splitter('\n').count
        == subject2.nodes.length + 1);
}

@("ui_gallery.inspector.handlesEveryPage")
@safe unittest
{
    // Every page can be the subject — including the Terminal page, whose view
    // is pure over the model and forks nothing.
    foreach (i, ref p; pages)
    {
        GalleryState s;
        s.page = i;
        auto b = Builder();
        auto tree = b.finish(inspectorBody(b, s));
        assert(tree.nodes.length > 0, "no tree for " ~ p.title);
    }
}

@("ui_gallery.inspector.clickSelectsAndTogglesContainers")
@safe unittest
{
    import registry : pageIndexOf;

    GalleryState s;
    s.page = pageIndexOf("primitives");

    // Ids below the panel's base are not the panel's.
    assert(!inspectorActivate(s, 5));

    // The root (node 0) is a container: activating selects and folds it.
    assert(inspectorActivate(s, hitInspTree + 0));
    assert(s.insp.selectedNode == 0);
    assert(!s.insp.open.isOpen(0), "a container click folds its subtree");
    assert(s.insp.rows.length >= 1);

    // A second activation opens it again.
    assert(inspectorActivate(s, hitInspTree + 0));
    assert(s.insp.open.isOpen(0));
}

@("ui_gallery.inspector.bodyStaysInsideThePanelWidth")
@safe unittest
{
    import sparkles.ui.widget : Visibility;

    // Tree rows and details are long and the panel is narrow: the body must
    // clip at the panel's width rather than pushing rows past the surface.
    GalleryState s;
    s.page = 1;

    auto b = Builder();
    const root = inspectorBody(b, s);
    auto tree = b.finish(root);
    auto frames = layout(tree, Constraints(maxW: inspectorInnerWidth(s)));

    void walk(uint n, bool clipped)
    {
        const node = tree.nodes[n];
        if (node.visibility == Visibility.collapsed)
            return;
        if (!clipped)
            assert(frames[n].rect.right <= inspectorInnerWidth(s),
                "the panel body overflows its own width");
        foreach (c; node.children)
            walk(c, clipped || node.clipX);
    }

    walk(root, false);
}
