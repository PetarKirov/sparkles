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

import sparkles.input : PointerEvent;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : Builder, WidgetTree;

import keymap : GalleryCommand, GalleryScope;
import state : GalleryState;

// Each page's view is imported under its own name rather than by package.
// `import pages.welcome;` would introduce the symbol `pages`, which is what the
// catalog below is called — and the collision is a compile error, not a
// shadowing surprise.
import pages.components_page : componentsAnimating = animating,
    componentsOnActivate = handleActivate,
    componentsOnCommand = handleCommand,
    componentsOnPointer = handlePointer, componentsStep = step,
    componentsView = view;
import pages.decoration_page : decorationView = view;
import pages.dock_page : dockOnCommand = handleCommand,
    dockOnPointer = handlePointer, dockStep = step, dockView = view;
import pages.machines_page : machinesAnimating = animating,
    machinesOnActivate = handleActivate, machinesOnCommand = handleCommand,
    machinesStep = step, machinesView = view;
import pages.scrolling_page : scrollingOnCommand = handleCommand,
    scrollingOnPointer = handlePointer,
    scrollingStep = step, scrollingView = view;
import pages.split_page : splitOnCommand = handleCommand, splitView = view;
import pages.tree_page : treeOnActivate = handleActivate,
    treeOnCommand = handleCommand, treeView_ = view;
import pages.layout_page : layoutOnCommand = handleCommand,
    layoutView = view;
import pages.primitives : primitivesView = view;
import pages.slots_page : slotsView = view;
import pages.themes_page : themesOnActivate = handleActivate,
    themesView = view;
import pages.table_page : tableOnCommand = handleCommand, tableView = view;
import pages.terminal_page : terminalOnActivate = handleActivate,
    terminalOnCommand = handleCommand, terminalOnPointer = handlePointer,
    terminalStep = step, terminalView = view;
import pages.text_page : textOnCommand = handleCommand, textView = view;
import pages.tracks_page : tracksOnCommand = handleCommand,
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
    /**
    The page's keymap scope — its rows in
    $(REF galleryBindings, keymap), reachable only while the page shows and
    the keyboard is in the content region. `GalleryScope.always` for a page
    with no keys of its own. The status bar and the help panel render the
    scope's rows, so a page's bindings are described exactly once.
    */
    GalleryScope scope_ = GalleryScope.always;
    /**
    The page's dispatch for its own commands, or `null`. Returns `true` iff
    the command was the page's.

    The shell resolves the key against the one table (the page's scope
    outranks the shell's rows — the old "first refusal in the content
    region", now row order) and offers the command here; the lifelines a
    page must never claim (`Tab`, quit, `?`) are pinned by
    `ui_gallery.keymap.noPageMayClaimTheShellsLifelines`.
    */
    bool function(ref GalleryState s, GalleryCommand cmd, ubyte arg) @safe
        onCommand;

    /**
    What a completed press on one of the page's own hit ids does, or `null`.
    Returns `true` iff the id was the page's.

    The shell routes its own chrome first and then offers the id here, so a
    page can be interactive without the shell importing it to find out how.
    */
    bool function(ref GalleryState s, size_t hitId) @safe onActivate;

    /**
    The page's own pointer handling, or `null`. Returns `true` iff it consumed
    the event.

    Handed the tree and the frames the painter used, because an affordance that
    is grabbed — a scrollbar, a divider — needs its $(B painted rect) and the
    shell has no way to know which node that is. Offered before the shell's own
    hover/press routing, since a grab in flight outranks whatever the pointer
    happens to be passing over.
    */
    bool function(ref GalleryState s, in PointerEvent p, in WidgetTree tree,
        in Frame[] frames) @safe onPointer;
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
        GalleryScope.pageLayout, &layoutOnCommand),
    Page("Tracks", "the grid subset, resolved live", &tracksView,
        GalleryScope.pageTracks, &tracksOnCommand),
    Page("Text", "wrapping and measurement", &textView,
        GalleryScope.pageText, &textOnCommand),
    Page("Themes", "thirty-six built-ins, live", &themesView,
        onActivate: &themesOnActivate),
    Page("Slots", "the semantic colour vocabulary", &slotsView),
    Page("Decoration", "box and text chrome", &decorationView),
    Page("Components", "the application chrome", &componentsView,
        GalleryScope.pageComponents, &componentsOnCommand,
        &componentsOnActivate, &componentsOnPointer),
    Page("Tree", "data, interaction, view", &treeView_,
        GalleryScope.pageTree, &treeOnCommand, &treeOnActivate),
    Page("Table", "one grid, two views", &tableView,
        GalleryScope.pageTable, &tableOnCommand),
    Page("Scrolling", "one thumb formula", &scrollingView,
        GalleryScope.pageScrolling, &scrollingOnCommand, null,
        &scrollingOnPointer),
    Page("State", "the interaction machines", &machinesView,
        GalleryScope.pageMachines, &machinesOnCommand, &machinesOnActivate),
    Page("Split", "a divider between two panes", &splitView,
        GalleryScope.pageSplit, &splitOnCommand),
    Page("Dock", "panes as a value", &dockView,
        GalleryScope.pageDock, &dockOnCommand, null, &dockOnPointer),
    Page("Terminal", "a shell as a widget", &terminalView,
        GalleryScope.pageTerminal, &terminalOnCommand, &terminalOnActivate,
        &terminalOnPointer),
];

/// The Terminal page's index — the shell needs it by name: keyboard capture
/// applies only while that page shows, and no other page is special.
enum size_t terminalPageIndex = () {
    foreach (i, ref p; pages)
        if (p.title == "Terminal")
            return i;
    assert(0, "the Terminal page left the catalog");
}();

/// Advances whatever the showing page animates, and says whether it wants
/// another frame. The shell owns the clock, so a page cannot read one.
bool stepPage(ref GalleryState s, int dtMs)
{
    machinesStep(s, dtMs);
    scrollingStep(s, dtMs);
    componentsStep(s, dtMs);
    dockStep(s, dtMs);
    terminalStep(s, dtMs);
    return machinesAnimating(s) || componentsAnimating(s);
}

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
        assert((p.scope_ == GalleryScope.always) == (p.onCommand is null),
            "a page's keymap scope and its command dispatch come together: "
            ~ p.title);
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

        // "Nothing crosses the edge unless a `clipX` ancestor put it there."
        // The clip state is carried down rather than tested per frame, because
        // content that is deliberately clipped — an unwrapped run, a tree dump
        // — is *supposed* to extend past its container.
        void walk(uint n, bool clipped)
        {
            const node = tree.nodes[n];
            if (node.visibility == Visibility.collapsed)
                return;
            if (!clipped)
                assert(frames[n].rect.right <= pane,
                    p.title ~ " overflows the pane horizontally");
            foreach (c; node.children)
                walk(c, clipped || node.clipX);
        }

        walk(tree.root, false);
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
