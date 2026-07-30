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

import git_status : GitBadge, gitBadge, GitStatus, GitStatusCache;

import sparkles.base.term_color : mix;
import sparkles.syntax : LabelSet, ResolvedTheme, resolveTheme, RgbColor,
    Theme, toRgb;
import sparkles.tui : CellStyle, Color, Grid;
import sparkles.tui.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    match, PointerAction, PointerButton, PointerEvent, ResizeEvent, WheelEvent;
import sparkles.ui.components.chrome : headerBar;
import sparkles.ui.components.tree_widget : FlatTreeRow, flatten, TreeData,
    TreeGlyphs, treeView;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.layout : layout;
import sparkles.ui.state : DisclosureState, scrollbarThumb;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;
import sparkles.ui_tui : paintGrid;

private enum RgbColor fallbackFg = RgbColor(0xcc, 0xcc, 0xcc);
private enum RgbColor fallbackBg = RgbColor(0x1e, 0x1e, 0x1e);

/// One filesystem node. `label`/`icon`/`iconFg`/`slot` are the tree view's
/// DbI capabilities: `slot` highlights the currently open document (`XPL3`);
/// the icon is per file type with its brand color, and a directory's icon
/// follows its disclosure state (`XPL6`).
struct FsEntry
{
    string name;
    string path;
    bool isDir;
    bool openDir;       // stamped at rebuild from the disclosure state
    RgbColor iconFg;
    bool hasIconFg;
    RgbColor labelFg;   // the open document's theme accent (XPL3)
    bool hasLabelFg;
    RgbColor rowBg;     // the open document's row band (XPL3)
    bool hasRowBg;
    string badge;       // git-status letter (XPF1; "" = none)
    RgbColor badgeFg;
    bool hasBadgeFg;
    GitStatus gitSt;    // the raw status (]g/[g navigation; ignored dimming)

    const(char)[] label() const @safe pure nothrow @nogc => name;
    const(char)[] icon() const @safe pure nothrow @nogc
        => isDir ? (openDir ? "\U0000F115 " : "\U0000F114 ") //  open /  closed
            : fsIcon(name).glyph;
}

/// The explorer's tree charset: no separate disclosure marker — the folder
/// icon (open/closed) already carries that state (`XPL6`).
enum TreeGlyphs explorerGlyphs = TreeGlyphs(closed: "", open: "", leaf: "");

/// A file-type icon: the Nerd glyph + its conventional brand color (`XPL6`,
/// the vscode-icons / snacks-explorer look). Directories use the folder pair.
struct FsIcon
{
    string glyph;
    RgbColor fg;
}

/// ditto — resolved from the file name (extension, with a few special names).
FsIcon fsIcon(scope const(char)[] name) @safe pure nothrow @nogc
{
    // The extension, lower-cased assumption-free (extensions here are ASCII).
    const(char)[] ext;
    foreach_reverse (i, ch; name)
        if (ch == '.')
        {
            ext = name[i + 1 .. $];
            break;
        }

    switch (ext)
    {
        case "d", "di":          return FsIcon("\U0000E7AF ", RgbColor(0xb0, 0x39, 0x31));
        case "md", "markdown":   return FsIcon("\U0000E609 ", RgbColor(0x51, 0x9a, 0xba));
        case "json":             return FsIcon("\U0000E60B ", RgbColor(0xcb, 0xcb, 0x41));
        case "js", "mjs", "jsx": return FsIcon("\U0000E781 ", RgbColor(0xf1, 0xe0, 0x5a));
        case "ts", "tsx":        return FsIcon("\U0000E628 ", RgbColor(0x31, 0x78, 0xc6));
        case "sh", "bash", "zsh", "fish":
            return FsIcon("\U0000E795 ", RgbColor(0x89, 0xe0, 0x51));
        case "nix":              return FsIcon("\U000F1105 ", RgbColor(0x7e, 0xba, 0xe4));
        case "py":               return FsIcon("\U0000E606 ", RgbColor(0x35, 0x72, 0xa5));
        case "rs":               return FsIcon("\U0000E7A8 ", RgbColor(0xde, 0xa5, 0x84));
        case "c", "h":           return FsIcon("\U0000E61E ", RgbColor(0x65, 0x9b, 0xd3));
        case "cpp", "cc", "cxx", "hpp":
            return FsIcon("\U0000E61D ", RgbColor(0x65, 0x9b, 0xd3));
        case "go":               return FsIcon("\U0000E627 ", RgbColor(0x00, 0xad, 0xd8));
        case "html", "htm":      return FsIcon("\U0000E736 ", RgbColor(0xe4, 0x4d, 0x26));
        case "css":              return FsIcon("\U0000E749 ", RgbColor(0x56, 0x3d, 0x7c));
        case "toml", "yaml", "yml", "ini", "cfg", "conf", "sdl":
            return FsIcon("\U0000E615 ", RgbColor(0x6d, 0x80, 0x86));
        case "lock":             return FsIcon("\U0000F023 ", RgbColor(0x6d, 0x80, 0x86));
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico":
            return FsIcon("\U0000F1C5 ", RgbColor(0xa0, 0x74, 0xc4));
        case "pdf":              return FsIcon("\U0000F1C1 ", RgbColor(0xb3, 0x0b, 0x00));
        case "zip", "gz", "xz", "zst", "tar", "7z":
            return FsIcon("\U0000F1C6 ", RgbColor(0xff, 0xb8, 0x6c));
        case "txt":              return FsIcon("\U0000F15C ", RgbColor(0x89, 0xa8, 0xc8));
        default:                 return FsIcon("\U0000F016 ", RgbColor(0x6d, 0x80, 0x86));
    }
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
    /// Rows of pane chrome above/below the tree (the TUI pane's header +
    /// status bars; the GUI pane has none). One value, so the wheel, the
    /// drag, and the thumb all share one scroll space.
    int chromeRows = 2;

    bool searching;
    char[128] qbuf;
    size_t qlen;

    string picked;  // the chosen file (empty = none yet)
    string current; // the open document's path — highlighted in the tree (XPL3)
    GitStatusCache git;   // async per-root status snapshot (XPF1)
    private char pending; // the ']'/'[' prefix of the ]g/[g sequences

    // Theme-derived interaction colors (XPL3/XPL5): the cursor row's tint and
    // the open document's accent come from the theme, matching the viewer's
    // selection chrome. Recomputed by rebuild, so a theme change re-skins.
    RgbColor selBg, accent, currentBg, sbTrack, sbThumb;

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
                auto fe = FsEntry(nm, e.name, e.isDir);
                // The type's brand color (dirs: the conventional folder amber).
                fe.iconFg = fe.isDir ? RgbColor(0xdc, 0xb6, 0x7a) : fsIcon(nm).fg;
                fe.hasIconFg = true;
                entries ~= fe;
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
                const isOpen = e.isDir && open.isOpen(e.path);
                e.openDir = isOpen; // the disclosure-state icon (XPL6)
                const idx = data.add(e, parent);
                if (!e.isDir)
                    continue;
                if (childrenVisible || isOpen)
                    addChildren(e.path, idx, childrenVisible && isOpen);
            }
        }

        if (qlen == 0)
            addChildren(root, uint.max, true);
        else
            addFiltered(root, uint.max);

        // Interaction colors from the theme (the viewer's selection language).
        const linkC = toRgb(theme[theme.labels.resolve("markup.link")].fg, pageFg);
        selBg = mix(pageBg, linkC, 0.35);
        accent = linkC;
        currentBg = mix(pageBg, linkC, 0.16);
        sbTrack = mix(pageBg, linkC, 0.22);
        sbThumb = mix(pageBg, linkC, 0.5);

        // The open document keeps its highlight through rebuilds (XPL3).
        if (current.length)
            foreach (ref n; data.nodes)
                if (n.value.path == current)
                {
                    n.value.labelFg = accent;
                    n.value.hasLabelFg = true;
                    n.value.rowBg = currentBg;
                    n.value.hasRowBg = true;
                }

        // Git-status badges (XPF1): kick/harvest the async snapshot and stamp
        // each node — the letter badge with its color, worst-wins on dirs
        // (the map propagates), and a dimmed label on ignored rows. The
        // result of an in-flight refresh lands on the next rebuild (or the
        // host's poll); manual refresh is `r`.
        git.root = root;
        git.ensureFresh();
        git.poll();
        const dimFg = mix(pageFg, pageBg, 0.55);
        if (git.map.present)
            foreach (ref n; data.nodes)
            {
                const st = git.map.statusOf(n.value.path, n.value.isDir);
                n.value.gitSt = st;
                const b = gitBadge(st);
                n.value.badge = b.letter;
                if (b.letter.length)
                {
                    n.value.badgeFg = b.fg;
                    n.value.hasBadgeFg = true;
                }
                if (st == GitStatus.ignored && n.value.path != current)
                {
                    n.value.labelFg = dimFg;
                    n.value.hasLabelFg = true;
                    n.value.iconFg = dimFg;
                }
            }

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
                e.openDir = true; // the filtered tree renders fully open
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

    int bodyRows() const @safe pure nothrow @nogc
        => height > chromeRows ? height - chromeRows : 1;

    /// Scrolls the viewport by `dy` rows (the wheel), leaving the cursor
    /// where it is; the next cursor move re-snaps the view to it.
    void scrollBy(long dy) @safe pure nothrow @nogc
    {
        top += dy;
        const maxTop = cast(long) rows.length - bodyRows;
        if (top > maxTop)
            top = maxTop;
        if (top < 0)
            top = 0;
    }

    void clamp() @safe pure nothrow @nogc
    {
        const n = cast(long) rows.length;
        if (sel >= n) sel = n ? n - 1 : 0;
        if (sel < 0) sel = 0;
        if (sel < top) top = sel;
        if (sel >= top + bodyRows) top = sel - bodyRows + 1;
        // Never leave dead space below (a reveal before the pane had its
        // real height can overshoot; the next sized clamp pulls back).
        const maxTop = n - bodyRows;
        if (top > maxTop) top = maxTop;
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
            selNode, explorerGlyphs, selBg, hasSelectionBg: true);

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

        // Scrollbar in the pane's last column when the tree overflows —
        // the one thumb formula (STM2), theme-tinted like the viewer's.
        if (cast(long) rows.length > bodyRows && width >= 2
            && width <= g.cols)
        {
            const thumb = scrollbarThumb(rows.length, bodyRows, top, bodyRows);
            const col = cast(ushort)(width - 1);
            foreach (r; 0 .. bodyRows)
            {
                const inThumb = r >= thumb.start && r < thumb.start + thumb.extent;
                CellStyle st;
                st.fg = Color.fromRgb(inThumb ? sbThumb : sbTrack);
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

    /// Manual refresh (`XPF4`, the deliberate alternative to FS watching):
    /// re-reads the filesystem and forces a git-status refresh, preserving
    /// the open set — the `open`/`expanded` split's payoff (`rebuild` always
    /// re-lists; `open` survives it by construction).
    void refreshNow() @system
    {
        git.force();
        rebuild();
    }

    /// `]g`/`[g`: the next/prev row (cyclic, in tree order) with a git
    /// change — a badge-carrying status; ignored rows are skipped.
    void jumpChange(int dir) @system
    {
        const n = cast(long) rows.length;
        if (n == 0)
            return;
        foreach (step; 1 .. n + 1)
        {
            const i = ((sel + dir * step) % n + n) % n;
            const st = data.nodes[rows[cast(size_t) i].node].value.gitSt;
            if (st > GitStatus.ignored)
            {
                sel = i;
                clamp();
                return;
            }
        }
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
            {
                const pk = pending;
                pending = 0;
                switch (e.ch)
                {
                    case 'q': return false;
                    case 'j': ++sel; clamp(); break;
                    case 'k': --sel; clamp(); break;
                    case 'g':
                        // g = top; ]g / [g = next/prev git change (XPF1).
                        if (pk == ']')
                            jumpChange(1);
                        else if (pk == '[')
                            jumpChange(-1);
                        else
                        {
                            sel = 0;
                            clamp();
                        }
                        break;
                    case 'G': sel = cast(long) rows.length - 1; clamp(); break;
                    case '/': searching = true; qlen = 0; rebuild(); break;
                    case ']', '[': pending = cast(char) e.ch; break;
                    case 'r': refreshNow(); break;
                    default: break;
                }
                break;
            }
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

    // Icons (XPL6): a closed dir shows the closed-folder glyph, files their
    // typed glyph + brand color.
    assert(x.data.nodes[x.rows[0].node].value.icon == "\U0000F114 ");
    assert(x.data.nodes[x.rows[1].node].value.icon == fsIcon("notes.md").glyph);
    assert(x.data.nodes[x.rows[1].node].value.hasIconFg);
    assert(x.data.nodes[x.rows[1].node].value.iconFg == fsIcon("x.md").fg);

    // Enter on the dir opens it; the child file appears under it — and the
    // dir's icon flips to the open folder.
    assert(x.activate());
    assert(x.rows.length == 3);
    assert(x.data.nodes[x.rows[0].node].value.icon == "\U0000F115 ");
    assert(x.data.nodes[x.rows[1].node].value.name == "app.d");
    assert(x.data.nodes[x.rows[1].node].value.iconFg == fsIcon("y.d").fg);

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
@("explorer.currentDoc.rowBandAndAccent")
@system
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    // XPL3: with the cursor on ANOTHER row, the open document still shows an
    // unmistakable indicator — the theme-tinted row band + the accent label.
    const root = buildPath(tempDir(), "hue-accent-probe");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "aaa.d"), "int a;\n");
    write(buildPath(root, "bbb.d"), "int b;\n");

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.pageFg = fallbackFg;
    x.pageBg = fallbackBg;
    x.width = 40;
    x.height = 10;
    x.current = buildPath(root, "aaa.d");
    x.rebuild();
    x.sel = 1; // the cursor on bbb.d

    Grid g;
    g.resize(40, 10);
    x.paint(g);

    bool sawBandAndAccent;
    foreach (ushort y; 0 .. g.rows)
        foreach (ushort xx; 0 .. cast(ushort)(g.cols - 4))
            if (g[xx, y].grapheme == "a"
                && g[cast(ushort)(xx + 1), y].grapheme == "a"
                && g[cast(ushort)(xx + 2), y].grapheme == "a"
                && g[xx, y].style.fg == Color.fromRgb(x.accent)
                && g[xx, y].style.bg == Color.fromRgb(x.currentBg))
                sawBandAndAccent = true;
    assert(sawBandAndAccent, "open-document row band + accent");
}

@("explorer.gitBadges.stampDimAndJump")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import sparkles.syntax : builtinDark, LabelSet;
    import sparkles.test_runner.skip : skipTest;
    import git_status : GitStatus;

    // A real repo: one committed-then-modified file, one untracked, one
    // ignored dir with contents.
    const root = buildPath(tempDir(), "hue-explorer-git-test");
    if (root.exists)
        rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    try
    {
        if (execute(["git", "init", "-q", root]).status != 0)
            skipTest("git init failed");
    }
    catch (Exception)
        skipTest("git not available");
    write(buildPath(root, "tracked.d"), "int a;\n");
    write(buildPath(root, ".gitignore"), "junk/\n");
    execute(["git", "-C", root, "add", "-A"]);
    execute(["git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t",
        "commit", "-qm", "init"]);
    write(buildPath(root, "tracked.d"), "int a; int b;\n"); // modified
    write(buildPath(root, "fresh.d"), "int c;\n");          // untracked
    mkdirRecurse(buildPath(root, "junk"));
    write(buildPath(root, "junk", "x.o"), "");              // ignored dir

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.pageFg = fallbackFg;
    x.pageBg = fallbackBg;
    x.width = 44;
    x.height = 10;
    x.rebuild(); // kicks the async refresh
    foreach (_; 0 .. 5000)
    {
        if (x.git.poll())
            break;
        Thread.sleep(1.msecs);
    }
    x.rebuild(); // stamp from the harvested snapshot

    GitStatus stOf(string name)
    {
        foreach (ref const n; x.data.nodes)
            if (n.value.name == name)
                return n.value.gitSt;
        assert(false, name);
    }

    string badgeOf(string name)
    {
        foreach (ref const n; x.data.nodes)
            if (n.value.name == name)
                return n.value.badge;
        assert(false, name);
    }

    // Badges: modified M, untracked ?, the ignored dir dimmed with no badge.
    assert(stOf("tracked.d") == GitStatus.modified);
    assert(badgeOf("tracked.d") == "M");
    assert(stOf("fresh.d") == GitStatus.untracked);
    assert(badgeOf("fresh.d") == "?");
    assert(stOf("junk") == GitStatus.ignored);
    assert(badgeOf("junk") == "");
    foreach (ref const n; x.data.nodes)
        if (n.value.name == "junk")
            assert(n.value.hasLabelFg, "the ignored row is dimmed");

    // ]g / [g cycle over change-carrying rows, skipping the ignored dir.
    x.sel = 0;
    x.jumpChange(1);
    assert(x.data.nodes[x.rows[cast(size_t) x.sel].node].value.gitSt
        > GitStatus.ignored);
    const first = x.sel;
    x.jumpChange(1);
    assert(x.sel != first, "a second change exists");
    x.jumpChange(-1);
    assert(x.sel == first);
}
