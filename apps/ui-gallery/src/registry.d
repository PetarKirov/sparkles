/**
The catalog: every page, in order, as $(B one flat table).

Not a class hierarchy and not design-by-introspection over modules. A page is a
pure view over $(REF GalleryState, state) — it appends a subtree to a `Builder`
and returns its root — so a plain array of function pointers says everything
there is to say, and lets the test sweep iterate the whole catalog without
naming a single page.

Adding a page is two lines: the module, and its row here.
*/
module registry;

import sparkles.ui.widget : Builder;

import state : GalleryState;

// Each page's view is imported under its own name rather than by package.
// `import pages.welcome;` would introduce the symbol `pages`, which is what the
// catalog below is called — and the collision is a compile error, not a
// shadowing surprise.
import pages.decoration_page : decorationView = view;
import pages.layout_page : layoutKeys = keys, layoutOnKey = handleKey,
    layoutView = view;
import pages.primitives : primitivesView = view;
import pages.slots_page : slotsView = view;
import pages.themes_page : themesKeys = keys, themesView = view;
import pages.text_page : textKeys = keys, textOnKey = handleKey,
    textView = view;
import pages.tracks_page : tracksKeys = keys, tracksOnKey = handleKey,
    tracksView = view;
import pages.welcome : welcomeView = view;

@safe:

/// One catalog entry.
struct Page
{
    /// The sidebar label. Also what `--page` matches, case-insensitively.
    string title;
    /// One line, shown beside the title in the header bar.
    string blurb;
    /// The view: appends a subtree to `b`, returns its root index.
    uint function(ref Builder b, in GalleryState s) @safe view;
    /// Page-local bindings, rendered into the status bar. Shell-wide keys
    /// (navigation, theme, quit) are not repeated here.
    immutable(string)[] keys;
    /**
    The page's own key handling, or `null`.

    Returns `true` iff it consumed the key. The shell tries its own bindings
    first, so a page cannot capture navigation and strand a reader on it —
    which is the failure mode of letting a page see input first.
    */
    bool function(ref GalleryState s, dchar ch) @safe onKey;
}

/**
The catalog, in the order the sidebar lists it.

`immutable`, so a page cannot be added at runtime and the sweep's coverage is a
compile-time fact rather than a hope.
*/
static immutable Page[] pages = [
    Page("Welcome", "what this build is", &welcomeView),
    Page("Primitives", "the ten widget kinds", &primitivesView),
    Page("Layout", "sizing, spacing, alignment", &layoutView,
        layoutKeys, &layoutOnKey),
    Page("Tracks", "the grid subset, resolved live", &tracksView,
        tracksKeys, &tracksOnKey),
    Page("Text", "wrapping and measurement", &textView,
        textKeys, &textOnKey),
    Page("Themes", "thirty-six built-ins, live", &themesView, themesKeys),
    Page("Slots", "the semantic colour vocabulary", &slotsView),
    Page("Decoration", "box and text chrome", &decorationView),
];

/// The index of the page `name` refers to — a title prefix (case-insensitive)
/// or a 1-based number — or `0` when nothing matches, which is `Welcome` and
/// therefore a safe answer for a typo on the command line.
size_t pageIndexOf(scope const(char)[] name)
{
    import std.ascii : isDigit;
    import std.algorithm : startsWith;
    import std.conv : to;
    import std.uni : toLower;

    if (name.length == 0)
        return 0;

    if (name.length <= 2 && name[0].isDigit)
    {
        const n = name.to!size_t;
        return n >= 1 && n <= pages.length ? n - 1 : 0;
    }

    const wanted = name.toLower;
    foreach (i, ref p; pages)
        if (p.title.toLower.startsWith(wanted))
            return i;
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — the catalog sweep. Every assertion here holds for every page that
// will ever be added, which is the reason the registry is a table.
// ---------------------------------------------------------------------------

@("ui_gallery.registry.everyPageIsNamedAndDistinct")
@safe unittest
{
    bool[string] seen;
    foreach (ref p; pages)
    {
        assert(p.title.length > 0, "a page needs a title — it is the nav label");
        assert(p.blurb.length > 0, "a page needs a blurb — it is the header line");
        assert(p.view !is null);
        assert(p.title !in seen, "two pages share a title: " ~ p.title);
        seen[p.title] = true;
    }
}

@("ui_gallery.registry.everyPageBuilds")
@safe unittest
{
    import sparkles.ui.geometry : Constraints, Size;
    import sparkles.ui.layout : layout;

    // Three surfaces: the conventional terminal, a large window, and one small
    // enough to be hostile. A page that only works at 80×24 is a page that
    // breaks the first time someone splits their terminal.
    static immutable Size[] surfaces = [Size(80, 24), Size(120, 40), Size(40, 10)];

    foreach (ref p; pages)
        foreach (surface; surfaces)
        {
            GalleryState s;
            s.surface = surface;

            auto b = Builder();
            const root = p.view(b, s);
            auto tree = b.finish(root);
            assert(tree.nodes.length > 0, p.title ~ " built an empty tree");
            assert(root < tree.nodes.length);

            auto frames = layout(tree,
                Constraints(maxW: s.contentWidth, maxH: s.contentHeight));
            assert(frames.length == tree.nodes.length);
        }
}

@("ui_gallery.registry.everyPageFitsThePaneWidth")
@safe unittest
{
    import sparkles.ui.geometry : Constraints, Size;
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : Visibility;

    // Horizontal overflow is a defect: the content pane does not scroll
    // sideways, so anything past the right edge is simply lost. Vertical
    // overflow is not — that is what the scroll view is for.
    foreach (ref p; pages)
    {
        GalleryState s;
        s.surface = Size(80, 24);
        const pane = s.contentWidth;

        auto b = Builder();
        auto tree = b.finish(p.view(b, s));
        auto frames = layout(tree, Constraints(maxW: pane, maxH: s.contentHeight));

        foreach (i, ref f; frames)
        {
            if (tree.nodes[i].visibility == Visibility.collapsed)
                continue;
            assert(f.rect.right <= pane,
                p.title ~ " overflows the pane horizontally");
        }
    }
}

@("ui_gallery.registry.pageIndexOf")
@safe unittest
{
    assert(pageIndexOf("") == 0);
    assert(pageIndexOf("welcome") == 0);
    assert(pageIndexOf("WEL") == 0);
    assert(pageIndexOf("1") == 0);

    // Out of range and unknown both land on the first page rather than
    // failing the run: `--page` is a convenience, not a contract.
    assert(pageIndexOf("99") == 0);
    assert(pageIndexOf("nonsense") == 0);
}
