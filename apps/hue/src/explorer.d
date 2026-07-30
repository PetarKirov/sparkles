// The file explorer (`TRV`/`TVU1`) — a directory target's interactive TUI
// entry: the generic three-layer tree (`sparkles.ui.components.tree_widget`)
// over the filesystem, with the case study's lazy `open` (user intent, the
// shared `DisclosureState`) / `expanded` (children read) split, a live filter
// in broot's tree-as-search-result mode (rebuild per keystroke, matches +
// their ancestors), and Enter handing the selected file to the `workspace`,
// which shows it in the viewer pane beside the tree (`XPL2`).
//
// Cross-platform (the cell grid and the event vocabulary are; the raw-mode
// loop that feeds it lives in `workspace`). A piped directory target keeps
// the static listing.
module explorer;

import std.algorithm.sorting : sort;
import std.file : dirEntries, SpanMode;
import std.path : baseName, buildPath;

import sparkles.syntax : LabelSet, ResolvedTheme, resolveTheme, RgbColor,
    Theme, toRgb;
import sparkles.tui : CellStyle, Color, Grid;
import sparkles.tui.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    match, PointerAction, PointerButton, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.ui.components.chrome : headerBar;
import sparkles.ui.components.tree_widget : FlatTreeRow, flatten, TreeData,
    treeView;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.layout : layout;
import sparkles.ui.state : DisclosureState, scrollbarThumb;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;
import sparkles.ui_tui : paintGrid;

private enum RgbColor fallbackFg = RgbColor(0xcc, 0xcc, 0xcc);
private enum RgbColor fallbackBg = RgbColor(0x1e, 0x1e, 0x1e);

/// One filesystem node. `label`/`icon`/`slot` are the tree view's DbI
/// capabilities; `slot` highlights the currently open document (`XPL3`).
struct FsEntry
{
    string name;
    string path;
    bool isDir;
    Slot slot = Slot.inherit;

    const(char)[] label() const @safe pure nothrow @nogc => name;
    const(char)[] icon() const @safe pure nothrow @nogc
        => isDir ? "\U0000F115 " : "\U0000F016 "; //  dir /  file
}

/// The explorer session: the arena is rebuilt (cheap, flat) whenever the open
/// set or the filter changes — the tree IS a function of (fs, open, query).
/// Full-screen (`runExplorer`) or the workspace's left pane.
struct ExplorerTui
{
    string root;
    ResolvedTheme theme;
    RgbColor pageFg, pageBg;
    immutable(Theme)* themeValue; // for the palette the chrome resolves against

    TreeData!FsEntry data;
    FlatTreeRow[] rows;
    DisclosureState!string open;  // user intent, keyed by path (survives rebuilds)
    long sel;                     // index into `rows`
    long top;
    int width, height;

    bool searching;
    char[128] qbuf;
    size_t qlen;

    string picked;  // the chosen file (empty = none yet)
    string current; // the open document's path — highlighted in the tree (XPL3)

    /// Selects + reveals `path` (`XPL4`): every ancestor directory under the
    /// root is opened, the tree rebuilds, and the node's row is selected and
    /// scrolled into view. Also marks it as the current document.
    void reveal(string path) @system
    {
        import std.path : dirname = dirName;

        current = path;
        for (auto d = dirname(path); d.length > root.length
            && d != "/" && d != "."; d = dirname(d))
            open = open.opened(d);
        rebuild();
        foreach (i, ref const r; rows)
            if (data.nodes[r.node].value.path == path)
            {
                sel = cast(long) i;
                break;
            }
        clamp();
    }

    private const(char)[] query() const return @safe pure nothrow @nogc
        => qbuf[0 .. qlen];

    /// The pane is consuming typed text (the workspace must not steal keys).
    bool inputActive() const @safe pure nothrow @nogc => searching;

    // Shallow directory listing: dirs first, each group name-sorted; dotfiles
    // and VCS internals are skipped (the explorer shows the working tree).
    private static FsEntry[] listDir(string dir) @system
    {
        FsEntry[] entries;
        try
            foreach (e; dirEntries(dir, SpanMode.shallow))
            {
                const nm = baseName(e.name);
                if (nm.length == 0 || nm[0] == '.')
                    continue;
                entries ~= FsEntry(nm, e.name, e.isDir);
            }
        catch (Exception)
        {
        }
        entries.sort!((a, b) => a.isDir != b.isDir ? a.isDir : a.name < b.name);
        return entries;
    }

    // Case-insensitive substring match (ASCII fold; allocation-free).
    private bool matches(scope const(char)[] name) const @safe pure nothrow @nogc
    {
        static char low(char c) => (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;

        const needle = query;
        if (needle.length == 0)
            return true;
        if (needle.length > name.length)
            return false;
        foreach (i; 0 .. name.length - needle.length + 1)
        {
            size_t j;
            while (j < needle.length && low(name[i + j]) == low(needle[j]))
                ++j;
            if (j == needle.length)
                return true;
        }
        return false;
    }

    /// Rebuilds the arena from the filesystem + the open set (+ the filter):
    /// children of open dirs recurse; closed dirs load one level (so their
    /// disclosure marker is honest); a filter keeps matches and the dirs on
    /// the way to them.
    void rebuild() @system
    {
        data = TreeData!FsEntry.init;

        // Unfiltered: children of visible dirs always load (so a closed but
        // visible dir's disclosure marker is honest — `expanded` runs one
        // level past `open`); recursion continues only down the visible+open
        // chain, so a deep tree costs what is on screen.
        void addChildren(string dir, uint parent, bool childrenVisible)
        {
            foreach (e; listDir(dir))
            {
                const idx = data.add(e, parent);
                if (!e.isDir)
                    continue;
                const isOpen = open.isOpen(e.path);
                if (childrenVisible || isOpen)
                    addChildren(e.path, idx, childrenVisible && isOpen);
            }
        }

        if (qlen == 0)
            addChildren(root, uint.max, true);
        else
            addFiltered(root, uint.max);

        // The open document keeps its highlight through rebuilds (XPL3).
        if (current.length)
            foreach (ref n; data.nodes)
                if (n.value.path == current)
                    n.value.slot = Slot.chromeAccent;

        rows = flatten(data, (uint i) @safe
            => qlen != 0 || open.isOpen(data.nodes[i].value.path));
        clamp();
    }

    // The filter pass: depth-first, a dir is added only if its subtree holds a
    // match (broot's tree-as-search-result — everything visible, fully open).
    private bool addFiltered(string dir, uint parent) @system
    {
        bool any;
        foreach (e; listDir(dir))
        {
            if (e.isDir)
            {
                // Probe the subtree first; add the dir only when it has matches.
                const mark = data.nodes.length;
                const idx = data.add(e, parent);
                const sub = addFiltered(e.path, idx);
                if (!sub && !matches(e.name))
                {
                    // Roll back the speculative subtree (append-only arena:
                    // truncate + unlink from the parent/sibling chain).
                    data.nodes = data.nodes[0 .. mark];
                    unlink(parent, cast(uint) mark);
                    continue;
                }
                any = true;
            }
            else if (matches(e.name))
            {
                data.add(e, parent);
                any = true;
            }
        }
        return any;
    }

    // Removes the (just-truncated) node `idx` from its parent's child chain.
    private void unlink(uint parent, uint idx) @safe pure nothrow @nogc
    {
        auto head = parent == uint.max ? &data.firstRoot
            : &data.nodes[parent].firstChild;
        if (*head == idx)
        {
            *head = uint.max;
            return;
        }
        for (auto at = *head; at != uint.max; at = data.nodes[at].nextSibling)
            if (data.nodes[at].nextSibling == idx)
            {
                data.nodes[at].nextSibling = uint.max;
                return;
            }
    }

    private int bodyRows() const @safe pure nothrow @nogc
        => height > 2 ? height - 2 : 1;

    void clamp() @safe pure nothrow @nogc
    {
        const n = cast(long) rows.length;
        if (sel >= n) sel = n ? n - 1 : 0;
        if (sel < 0) sel = 0;
        if (sel < top) top = sel;
        if (sel >= top + bodyRows) top = sel - bodyRows + 1;
        if (top < 0) top = 0;
    }

    void paint(ref Grid g) @system
    {
        CellStyle page;
        page.fg = Color.fromRgb(pageFg);
        page.bg = Color.fromRgb(pageBg);
        g.fillRect(0, 0, cast(ushort)(width < g.cols ? width : g.cols),
            g.rows, page);

        // Header + tree + status through one widget pipeline. The tree is
        // viewport-sliced (guides are per-row, so slicing is safe).
        auto b = Builder();
        const name = b.add(Widget(kind: WidgetKind.text, text: root,
            slot: Slot.chromeAccent));
        import std.conv : text;
        const pos = b.add(Widget(kind: WidgetKind.text,
            text: text(rows.length ? sel + 1 : 0, "/", rows.length),
            slot: Slot.gutter));
        const hdr = headerBar(b, [name], null, [pos]);

        const first = cast(size_t) top;
        const last = first + bodyRows > rows.length ? rows.length
            : first + bodyRows;
        const selNode = sel < cast(long) rows.length
            ? rows[cast(size_t) sel].node : uint.max;
        const tree = treeView(b, data, rows[first .. last],
            (uint i) @safe => qlen != 0 || open.isOpen(data.nodes[i].value.path),
            selNode);

        Widget colW = Widget(kind: WidgetKind.column, children: [hdr, tree],
            width: SizeSpec.fixed(width));
        auto wt = b.finish(b.add(colW));
        paintGrid(g, pageBg, buildDisplayList(wt, layout(wt),
            themeValue.effectivePalette, pageFg, pageBg));

        // The status bar pinned to the bottom row (its own one-row pipeline).
        auto sb = Builder();
        const status = sb.add(Widget(kind: WidgetKind.text,
            text: searching ? text("/", query, "▏")
                : "↑↓ move · ⏎/→ open · ← close · / filter · q quit",
            slot: searching ? Slot.inherit : Slot.gutter));
        const bar = headerBar(sb, [status], null, null);
        Widget barCol = Widget(kind: WidgetKind.column, children: [bar],
            width: SizeSpec.fixed(width));
        auto bt = sb.finish(sb.add(barCol));
        paintGrid(g, pageBg, buildDisplayList(bt, layout(bt),
            themeValue.effectivePalette, pageFg, pageBg),
            0, height > 0 ? height - 1 : 0);

        // Scrollbar in the last column when the tree overflows.
        if (cast(long) rows.length > bodyRows && g.cols >= 2)
        {
            const thumb = scrollbarThumb(rows.length, bodyRows, top, bodyRows);
            const col = cast(ushort)(g.cols - 1);
            foreach (r; 0 .. bodyRows)
            {
                const inThumb = r >= thumb.start && r < thumb.start + thumb.extent;
                CellStyle st;
                st.fg = Color.fromRgb(inThumb ? pageFg : pageBg);
                st.bg = Color.fromRgb(pageBg);
                g.putText(col, cast(ushort)(r + 1), inThumb ? "█" : "░", st);
            }
        }
    }

    // Returns false to quit the explorer (picked empty = quit for good).
    bool handle(in Event e) @system
    {
        if (searching)
            return handleSearch(e);
        return e.match!(
            (in KeyEvent k) => handleKey(k),
            (in WheelEvent w) {
                sel += 3 * w.dy;
                clamp();
                return true;
            },
            (in PointerEvent p) {
                if (p.button == PointerButton.left
                    && p.action == PointerAction.press && p.pos.y >= 1
                    && p.pos.y <= bodyRows)
                {
                    const i = top + (p.pos.y - 1);
                    if (i >= 0 && i < cast(long) rows.length)
                    {
                        const already = i == sel;
                        sel = i;
                        if (already)
                            return activate();
                    }
                }
                return true;
            },
            (in EndOfInput _) => false,
            _ => true,
        );
    }

    /// Enter/→ on a dir toggles it; on a file, picks it (`picked` is set and
    /// `false` returned — the host opens it and clears `picked`).
    bool activate() @system
    {
        if (sel >= cast(long) rows.length)
            return true;
        ref const v = data.nodes[rows[cast(size_t) sel].node].value;
        if (v.isDir)
        {
            open = open.toggled(v.path);
            rebuild();
            return true;
        }
        picked = v.path;
        return false;
    }

    private bool handleKey(in KeyEvent e) @system
    {
        switch (e.key)
        {
            case Key.up:    --sel; clamp(); break;
            case Key.down:  ++sel; clamp(); break;
            case Key.pageUp:   sel -= bodyRows; clamp(); break;
            case Key.pageDown: sel += bodyRows; clamp(); break;
            case Key.home:  sel = 0; clamp(); break;
            case Key.end:   sel = cast(long) rows.length - 1; clamp(); break;
            case Key.enter, Key.right:
                return activate();
            case Key.left:
                // Close the selected dir, or jump to the parent.
                if (sel < cast(long) rows.length)
                {
                    const node = rows[cast(size_t) sel].node;
                    ref const v = data.nodes[node].value;
                    if (v.isDir && open.isOpen(v.path))
                    {
                        open = open.closed(v.path);
                        rebuild();
                    }
                    else if (data.nodes[node].parent != uint.max)
                    {
                        const p = data.nodes[node].parent;
                        foreach (i, ref const r; rows)
                            if (r.node == p)
                            {
                                sel = cast(long) i;
                                break;
                            }
                        clamp();
                    }
                }
                break;
            case Key.escape:
                return false;
            case Key.char_:
                switch (e.ch)
                {
                    case 'q': return false;
                    case 'j': ++sel; clamp(); break;
                    case 'k': --sel; clamp(); break;
                    case 'g': sel = 0; clamp(); break;
                    case 'G': sel = cast(long) rows.length - 1; clamp(); break;
                    case '/': searching = true; qlen = 0; rebuild(); break;
                    default: break;
                }
                break;
            default: break;
        }
        return true;
    }

    private bool handleSearch(in Event ev) @system
    {
        return ev.match!((in KeyEvent e) {
            switch (e.key)
            {
                case Key.char_:
                    if (qlen < qbuf.length)
                        qbuf[qlen++] = cast(char) e.ch;
                    rebuild();
                    break;
                case Key.backspace:
                    if (qlen)
                        --qlen;
                    rebuild();
                    break;
                case Key.enter:
                    searching = false;
                    break;
                case Key.escape:
                    searching = false;
                    qlen = 0;
                    rebuild();
                    break;
                default: break;
            }
            return true;
        }, (in EndOfInput _) => false, _ => true);
    }
}

@("explorer.tree.lazyOpenFilterAndPaint")
@system
unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.algorithm.searching : canFind;
    import sparkles.syntax : builtinDark, LabelSet;

    // tmp/{notes.md, src/{app.d}} — a dir with a nested renderable file.
    const root = buildPath(tempDir(), "hue-explorer-test");
    mkdirRecurse(buildPath(root, "src"));
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "notes.md"), "# hi\n");
    write(buildPath(root, "src", "app.d"), "void main() {}\n");

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.pageFg = toRgb(x.theme.defaults.fg, fallbackFg);
    x.pageBg = toRgb(x.theme.defaults.bg, fallbackBg);
    x.width = 50;
    x.height = 8;
    x.rebuild();

    // Closed root listing: the dir first, then the file — the dir's children
    // are loaded (expanded) but not shown (not open), so its marker is honest.
    assert(x.rows.length == 2);
    assert(x.data.nodes[x.rows[0].node].value.name == "src");
    assert(x.data.hasChildren(x.rows[0].node)); // expanded past open
    assert(x.data.nodes[x.rows[1].node].value.name == "notes.md");

    // Enter on the dir opens it; the child file appears under it.
    assert(x.activate());
    assert(x.rows.length == 3);
    assert(x.data.nodes[x.rows[1].node].value.name == "app.d");

    // Paint: header, guides, labels, status all through the widget pipeline.
    Grid g;
    g.resize(50, 8);
    x.paint(g);
    string row(ushort y)
    {
        string s;
        foreach (xx; 0 .. g.cols)
            s ~= g[cast(ushort) xx, y].grapheme;
        return s;
    }
    assert(row(1).canFind("src"), row(1));
    assert(row(2).canFind("app.d"), row(2));
    assert(row(3).canFind("notes.md"), row(3));
    assert(row(7).canFind("filter"), row(7)); // the status bar hints

    // The live filter: "app" keeps the match and the dir on the way to it.
    x.qbuf[0 .. 3] = "app";
    x.qlen = 3;
    x.rebuild();
    assert(x.rows.length == 2);
    assert(x.data.nodes[x.rows[0].node].value.name == "src");
    assert(x.data.nodes[x.rows[1].node].value.name == "app.d");

    // Enter on the file picks it (ends the session).
    x.sel = 1;
    assert(!x.activate());
    assert(x.picked.canFind("app.d"));
}
