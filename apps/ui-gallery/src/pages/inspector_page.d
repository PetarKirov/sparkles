/**
The Inspector page: the toolkit looking at itself.

`dumpTree` prints one depth-indented line per node — kind, resolved size,
absolute position, and a text node's content. It is the first thing to reach for
when a layout is wrong, and the reason it belongs in the catalog is that most
people never learn it exists.

The subject is the $(B previously viewed) page, not this one. Dumping the
inspector would show the dump, which is both useless and unbounded; showing what
you were just looking at is the question anyone actually has.
*/
module pages.inspector_page;

import std.algorithm : count, splitter;
import std.conv : text;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.geometry : Constraints, SizeSpec;
import sparkles.ui.layout : dumpTree, layout;
import sparkles.ui.state : elementKeys, hoverTargets;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import kit;
import registry : pages;
import state : GalleryState;

@safe:

/// ditto
static immutable string[] keys = ["+/- lines"];

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    // The subject is built in its OWN builder, so its arena indices are its
    // own and the dump reads the way it would if that page were showing.
    const subject = pages[subjectIndex(s)];
    auto sb = Builder();
    auto subjectTree = sb.finish(subject.view(sb, s));
    auto frames = layout(subjectTree, Constraints(maxW: w));

    const dump = dumpTree(subjectTree, frames);
    const targets = hoverTargets(subjectTree, frames);
    const keyed = elementKeys(subjectTree);

    uint[] body_;
    body_ ~= heading(b, "Inspector · dumpTree");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "One depth-indented line per node: the kind, the resolved size, the "
        ~ "absolute position, and a text node's content. Everything before the "
        ~ "painter is pure, so this is the whole truth about a frame — there "
        ~ "is no later stage that could move something.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "subject", [
        kv(b, "page", subject.title, 16, Slot.chromeAccent),
        kv(b, "laid out at", text(w, " cells wide"), 16, Slot.code),
        kv(b, "nodes", subjectTree.nodes.length.text, 16, Slot.code),
        kv(b, "hit targets", targets.length.text, 16, Slot.code),
        kv(b, "element keys", keyed.length.text, 16, Slot.code),
        kv(b, "root size", text(frames[subjectTree.root].rect.width, " × ",
            frames[subjectTree.root].rect.height), 16, Slot.code),
    ]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Move to another page and come back: the subject follows what you were "
        ~ "last looking at, since dumping this page would only show you the "
        ~ "dump.", w);
    body_ ~= spacer(b);

    body_ ~= section(b, "the tree", dumpLines(b, dump, s.inspectorLines, w));

    return column(b, body_);
}

/**
Which page to dump: the last one viewed, unless that is this one.

$(B Not a nicety.) Dumping itself is unbounded recursion — this view would call
this view — and the failure mode is a stack overflow, not a wrong picture. The
check is on the view $(I function), not on an index, because a page does not
know where it sits in the catalog and a hardcoded number would rot the first
time one was inserted above it.
*/
size_t subjectIndex(in GalleryState s) pure nothrow @nogc
{
    if (s.lastPage < pages.length && pages[s.lastPage].view !is &view)
        return s.lastPage;
    return 0;
}

/// The dump, as one clipped text node per line.
///
/// Per line rather than one wrapped run, because a dump's indentation is its
/// structure: wrapping a deep line would fold it under a shallower one and
/// the shape — the only reason to read a dump — would be gone.
private uint[] dumpLines(ref Builder b, string dump, int limit, int width)
{
    uint[] rows;
    size_t shown;
    foreach (line; dump.splitter('\n'))
    {
        if (shown >= limit)
            break;
        if (line.length == 0)
            continue;
        rows ~= b.add(Widget(
            kind: WidgetKind.column,
            children: [label(b, line, Slot.code)],
            width: SizeSpec.fixed(width - 4),
            clipX: true,
        ));
        ++shown;
    }

    const total = dump.splitter('\n').count;
    if (total > shown)
        rows ~= label(b, text("… ", total - shown, " more lines (press +)"),
            Slot.muted);
    return rows;
}

/// ditto
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    switch (k.ch)
    {
        case '+': case '=': s.inspectorLines = clampLines(s.inspectorLines + 10); return true;
        case '-': s.inspectorLines = clampLines(s.inspectorLines - 10); return true;
        default: return false;
    }
}

/// A dump can run to hundreds of lines; the pane scrolls, but a page that
/// built every one of them on every frame would be paying for a wall of text
/// nobody scrolled to.
private int clampLines(int n) pure nothrow @nogc
    => n < 10 ? 10 : (n > 400 ? 400 : n);

@("ui_gallery.pages.inspectorDumpsTheSubjectNotItself")
@safe unittest
{
    import std.algorithm : canFind;
    import registry : pageIndexOf;

    // Dumping this page would print the dump; the subject is what you were
    // last looking at, which is the question anyone actually has.
    GalleryState s;
    s.page = pageIndexOf("inspector");
    s.lastPage = pageIndexOf("primitives");

    auto b = Builder();
    auto tree = b.finish(view(b, s));

    bool named;
    foreach (ref n; tree.nodes)
        named |= n.text == "Primitives";
    assert(named, "the inspector names its subject");
}

@("ui_gallery.pages.inspectorDumpMatchesTheEngine")
@safe unittest
{
    import registry : pageIndexOf;

    // The numbers the page reports come from the same layout the dump does —
    // a panel showing a node count that disagreed with the tree beneath it
    // would be worse than no panel.
    GalleryState s;
    s.lastPage = pageIndexOf("layout");

    auto sb = Builder();
    auto subject = sb.finish(pages[s.lastPage].view(sb, s));
    auto frames = layout(subject, Constraints(maxW: s.contentWidth));

    const dump = dumpTree(subject, frames);
    // `dumpTree` writes one line per node plus a trailing newline.
    assert(dump.splitter('\n').count == subject.nodes.length + 1);
}

@("ui_gallery.pages.inspectorHandlesEverySubject")
@safe unittest
{
    // Every page, INCLUDING this one. Dumping itself is unbounded recursion,
    // and it crashed exactly here the first time — a stack overflow, which is
    // why the guard is in the page and not in the shell that usually prevents
    // `lastPage` from pointing at the showing page.
    foreach (i, ref p; pages)
    {
        GalleryState s;
        s.lastPage = i;
        auto b = Builder();
        auto tree = b.finish(view(b, s));
        assert(tree.nodes.length > 0, "no dump for " ~ p.title);

        if (p.view is &view)
            assert(subjectIndex(s) != i, "the inspector must not dump itself");
        else
            assert(subjectIndex(s) == i);
    }

    // An out-of-range `lastPage` — which no route produces, but which a future
    // one might — falls back rather than indexing past the catalog.
    GalleryState bad;
    bad.lastPage = pages.length + 7;
    assert(subjectIndex(bad) == 0);
}

@("ui_gallery.pages.inspectorLineLimitIsBounded")
@safe unittest
{
    GalleryState s;
    foreach (_; 0 .. 100)
        handleKey(s, KeyEvent(Key.char_, '+'));
    assert(s.inspectorLines == 400);
    foreach (_; 0 .. 100)
        handleKey(s, KeyEvent(Key.char_, '-'));
    assert(s.inspectorLines == 10);
}
