/**
The inspector panel: the toolkit looking at itself, beside whatever it shows.

`dumpTree` prints one depth-indented line per node — kind, resolved size,
absolute position, and a text node's content. It is the first thing to reach for
when a layout is wrong, and the reason it belongs in the catalog is that most
people never learn it exists.

It used to be a $(B page), dumping the previously viewed one — which meant the
subject was never on screen while its dump was. As a shell panel toggled with
`|` it sits beside the showing page and dumps $(I that), live: move to another
page, press a knob, resize — the dump follows. A panel cannot dump itself into
recursion the way a page could: it is not in the catalog, so no `view` here ever
calls back into it.
*/
module inspector;

import std.algorithm : count, splitter;
import std.conv : text;

import sparkles.ui.geometry : Constraints, SizeSpec;
import sparkles.ui.layout : dumpTree, layout;
import sparkles.ui.state : elementKeys, hoverTargets;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import kit;
import registry : pages;
import scrollbars : gutterCells;
import state : GalleryState;

@safe:

/// The width the panel's rows are built at: the dock-arranged column less its
/// own horizontal padding and the bar's gutter. Fixed rather than `grow`,
/// because the body lives inside a scroll viewport, where `grow` collapses to
/// natural width (the caught defect the spec's ledger records) — and read from
/// the state, because the panel's divider is draggable.
int inspectorInnerWidth(in GalleryState s) pure nothrow @nogc
    => s.inspCols - 2 - gutterCells;

/// A dump can run to hundreds of lines; the panel scrolls, but a body that
/// built every one of them on every frame would be paying for a wall of text
/// nobody scrolled to.
enum int maxDumpLines = 400;

/**
The panel's body: the showing page rebuilt in its $(B own) builder, laid out at
the width the content pane actually has — so the dump describes the frame on
screen, not a hypothetical one — then the numbers and the tree.

The rebuild is what pages being pure views over the state buys: calling
`pages[s.page].view` twice a frame cannot double anything, because a page owns
nothing to double.
*/
uint inspectorBody(ref Builder b, in GalleryState s)
{
    const subject = pages[s.page];
    auto sb = Builder();
    auto subjectTree = sb.finish(subject.view(sb, s));
    auto frames = layout(subjectTree, Constraints(maxW: s.contentWidth));

    const dump = dumpTree(subjectTree, frames);
    const targets = hoverTargets(subjectTree, frames);
    const keyed = elementKeys(subjectTree);
    const iw = inspectorInnerWidth(s);

    uint[] rows;
    rows ~= b.add(Widget(
        kind: WidgetKind.text,
        text: "inspector · dumpTree",
        slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true),
    ));
    rows ~= rule(b, iw);
    rows ~= kv(b, "page", subject.title, 12, Slot.chromeAccent);
    rows ~= kv(b, "laid out at", text(s.contentWidth, " cells wide"), 12,
        Slot.code);
    rows ~= kv(b, "nodes", subjectTree.nodes.length.text, 12, Slot.code);
    rows ~= kv(b, "hit targets", targets.length.text, 12, Slot.code);
    rows ~= kv(b, "element keys", keyed.length.text, 12, Slot.code);
    rows ~= kv(b, "root size", text(frames[subjectTree.root].rect.width, " × ",
        frames[subjectTree.root].rect.height), 12, Slot.code);
    rows ~= rule(b, iw);
    rows ~= dumpLines(b, dump, iw);

    return b.add(Widget(
        kind: WidgetKind.column,
        children: rows,
        width: SizeSpec.fixed(iw),
    ));
}

/// A fixed-width rule — `kit.hrule` grows, and `grow` collapses to nothing
/// inside the panel's scroll viewport.
private uint rule(ref Builder b, int width)
    => b.add(Widget(
        kind: WidgetKind.box,
        slot: Slot.border,
        width: SizeSpec.fixed(width),
        height: SizeSpec.fixed(1),
        paintBackground: true,
        stretch: true,
    ));

/// The dump, as one clipped text node per line.
///
/// Per line rather than one wrapped run, because a dump's indentation is its
/// structure: wrapping a deep line would fold it under a shallower one and
/// the shape — the only reason to read a dump — would be gone.
private uint[] dumpLines(ref Builder b, string dump, int width)
{
    uint[] rows;
    size_t shown;
    foreach (line; dump.splitter('\n'))
    {
        if (shown >= maxDumpLines)
            break;
        if (line.length == 0)
            continue;
        rows ~= b.add(Widget(
            kind: WidgetKind.column,
            children: [label(b, line, Slot.code)],
            width: SizeSpec.fixed(width),
            clipX: true,
        ));
        ++shown;
    }

    const total = dump.splitter('\n').count;
    if (total > shown)
        rows ~= label(b, text("… ", total - shown, " more lines"), Slot.muted);
    return rows;
}

@("ui_gallery.inspector.dumpsTheShowingPage")
@safe unittest
{
    import registry : pageIndexOf;

    // The panel names and dumps the page beside it — the question the old
    // last-page inspector could never answer while its subject was hidden.
    GalleryState s;
    s.page = pageIndexOf("primitives");

    auto b = Builder();
    auto tree = b.finish(inspectorBody(b, s));

    bool named;
    foreach (ref n; tree.nodes)
        named |= n.text == "Primitives";
    assert(named, "the panel names its subject");
}

@("ui_gallery.inspector.dumpMatchesTheEngine")
@safe unittest
{
    import registry : pageIndexOf;

    // The numbers the panel reports come from the same layout the dump does —
    // a panel showing a node count that disagreed with the tree beneath it
    // would be worse than no panel.
    GalleryState s;
    s.page = pageIndexOf("layout");

    auto sb = Builder();
    auto subject = sb.finish(pages[s.page].view(sb, s));
    auto frames = layout(subject, Constraints(maxW: s.contentWidth));

    const dump = dumpTree(subject, frames);
    // `dumpTree` writes one line per node plus a trailing newline.
    assert(dump.splitter('\n').count == subject.nodes.length + 1);
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
        assert(tree.nodes.length > 0, "no dump for " ~ p.title);
    }
}

@("ui_gallery.inspector.bodyStaysInsideThePanelWidth")
@safe unittest
{
    import sparkles.ui.widget : Visibility;

    // Dump lines are long and the panel is narrow: every line must clip at
    // the panel's width rather than pushing the body row past the surface.
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
