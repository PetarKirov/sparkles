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
import std.conv : text;
import std.file : dirEntries, SpanMode;
import std.path : baseName, buildPath, dirName;

import diff_session : FileChange, SessionEntry;
import core.time : Duration;
import keymap : Command, KeyContext;
import lantern : LanternState, ltnStep = step, ltnTick = tick,
    untilShown, LtnStepKind = StepKind;
import git_status : GitBadge, gitBadge, GitStatus, GitStatusCache;

import sparkles.base.term_color : mix;
import sparkles.syntax : LabelSet, ResolvedTheme, resolveTheme, RgbColor,
    Theme, toRgb;
import sparkles.input : EndOfInput, Event, isEndOfInput, Key, KeyEvent,
    match, Point, PointerAction, PointerButton, PointerEvent, ResizeEvent,
    WheelEvent;
import sparkles.ui.components.chrome : headerBar;
import sparkles.ui.components.tree_view : jumpMatching, measureContent,
    treeActivate = activate, treeCollapseOrUp = collapseOrUp, TreeStep,
    TreeViewState, viewSlice;
import sparkles.ui.components.tree_widget : FlatTreeRow, flatten, TreeData,
    TreeGlyphs, treeView;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Rect, SizeSpec;
import sparkles.ui.layout : layout;
import sparkles.ui.state : DisclosureState, LineEditState;
import sparkles.ui.style : Palette, Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind;
import sparkles.ui_tui : CellStyle, Color, Grid, paintGrid;

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
    /// `TVU6`: index into the diff session this row came from, or `-1` for a
    /// filesystem row (and for the directories a session tree synthesizes).
    /// Activating a row with an index jumps the diff pane instead of loading
    /// a document.
    int sessionIndex = -1;

    const(char)[] label() const @safe pure nothrow @nogc => name;
    /// The tree view's activation capability: a directory toggles even when
    /// empty (`hasChildren` would call it a leaf and "pick" it).
    bool expandable() const @safe pure nothrow @nogc => isDir;
    const(char)[] icon() const @safe pure nothrow @nogc
        => isDir ? (openDir ? "\U0000F115 " : "\U0000F114 ") //  open /  closed
            : fsIcon(name).glyph;
}

/// The last `/` in `p`, or `size_t.max` when it has none — the one path split
/// a session tree needs, without dragging `std.path` into a `@nogc` context.
private size_t lastSlash(scope const(char)[] p) @safe pure nothrow @nogc
{
    foreach_reverse (i, c; p)
        if (c == '/')
            return i;
    return size_t.max;
}

/// `TVU6`: a session file's change kind as the explorer's git-status
/// vocabulary, so one badge language covers the tree and the diff headers.
private GitStatus sessionGitStatus(FileChange c) @safe pure nothrow @nogc
{
    final switch (c) with (FileChange)
    {
        case modified: return GitStatus.modified;
        case added:    return GitStatus.added;
        case removed:  return GitStatus.deleted;
        case renamed:  return GitStatus.renamed;
    }
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

    /// `TVU6`: when non-empty, the pane lists this changed-file session
    /// instead of walking the filesystem — the diff's shape is what a
    /// reviewer needs from a tree, and the working tree is not it.
    const(SessionEntry)[] session;

    TreeData!FsEntry data;

    /// The whole interaction layer — opened set (keyed by path, so it
    /// survives rebuilds), cursor + viewport, both scrollbars, and the live
    /// filter — is the shared component's state value; `alias this` keeps
    /// the established names (`sel`, `top`, `rows`, `open`, …) working.
    TreeViewState!string tv;
    /// ditto
    alias tv this;

    /// Whether this pane holds the workspace focus — the header title
    /// renders accented when focused, muted otherwise (like the viewer's).
    bool focused;

    /// The key guide's pending path (`LTN2`), so `gg` and `<leader>` work in
    /// this pane too — the same machine the viewer uses, not a copy.
    private LanternState lantern;

    /// How long until the guide's panel appears (`LTN4`); `Duration.max` when
    /// nothing is pending. The host uses it as its poll timeout, so the panel
    /// opens on time with no keystroke to wake it.
    Duration untilLanternShown() const @safe pure nothrow @nogc
        => .untilShown(lantern);

    /// ditto — advances the clock when that wait expires.
    void tickLantern(Duration elapsed) @safe pure nothrow @nogc
    {
        ltnTick(lantern, elapsed);
    }

    // Visibility toggles (XPF2), state shown in the status bar: dotfiles are
    // hidden by default; git-ignored entries are listed (dimmed) by default.
    bool showHidden;
    bool showIgnored = true;

    // Glob filters (XPF2, snacks precedence: include overrides hidden,
    // ignored, AND exclude). Matched against the entry name and its
    // root-relative path; a dir passes when it might contain includes.
    string[] includeGlobs;
    string[] excludeGlobs;

    string picked;  // the chosen file (empty = none yet)
    /// `TVU6`: the session index of the chosen row, or `-1` when the pick was
    /// an ordinary filesystem row (so the host loads it as a document).
    int pickedSession = -1;
    string current; // the open document's path — highlighted in the tree (XPL3)
    GitStatusCache git;   // async per-root status snapshot (XPF1)

    // Theme-derived interaction colors (XPL3/XPL5): the cursor row's tint and
    // the open document's accent come from the theme, matching the viewer's
    // selection chrome. Recomputed by rebuild, so a theme change re-skins.
    RgbColor selBg, accent, currentBg, sbTrack, sbThumb;
    /// The slot palette this pane's pipelines resolve against — the theme's
    /// effective palette with the link-tinted `track`/`thumb` written in
    /// (B-1, one color authority; the viewer model does the same).
    Palette palette;

    /// Selects + reveals `path` (`XPL4`): every ancestor directory under the
    /// root is opened, the tree rebuilds, and the node's row is selected and
    /// scrolled into view. Also marks it as the current document.
    void reveal(string path) @system
    {
        import std.algorithm.searching : startsWith;
        import std.path : dirname = dirName;

        // A path outside the root re-roots outward to its directory (XPF3).
        if (root.length && path != root
            && !path.startsWith(root == "/" ? root : root ~ "/"))
            setRoot(dirname(path));

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

    private const(char)[] query() const @safe pure nothrow @nogc
        => filter.text;

    /// The pane is consuming typed text (the workspace must not steal keys).
    bool inputActive() const @safe pure nothrow @nogc => searching;

    // ── The live filter, drivable by either backend's input ───────────────
    /// `/`: enter filter mode (broot's tree-as-search-result — XPL/TRV5).
    void filterStart() @system
    {
        filter = filter.started();
        rebuild();
    }

    /// ditto — a typed character narrows per keystroke.
    void filterInput(dchar c) @system
    {
        const next = filter.typed(c);
        if (next == filter)
            return;
        filter = next;
        rebuild();
    }

    /// ditto
    void filterBackspace() @system
    {
        filter = filter.erased();
        rebuild();
    }

    /// Enter keeps the filtered tree; Esc clears it.
    void filterAccept() @safe pure nothrow
    {
        filter = filter.accepted();
    }

    /// ditto
    void filterCancel() @system
    {
        filter = filter.cancelled();
        rebuild();
    }

    // Shallow directory listing: dirs first, each group name-sorted. All
    // visibility policy (hidden / ignored / globs) lives in `visible`;
    // `.git` itself never lists.
    private FsEntry[] listDir(string dir) @system
    {
        FsEntry[] entries;
        try
            foreach (e; dirEntries(dir, SpanMode.shallow))
            {
                const nm = baseName(e.name);
                if (nm.length == 0 || nm == ".git")
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
    /**
    `TVU6`: builds the tree from the diff session rather than the filesystem —
    the changed files as a path-prefix tree, each leaf badged with its status
    and labelled with its `+N −M` counts.

    Directories are **synthesized from the paths**, not listed: a changed-file
    tree must show exactly the files that changed, and a directory listing
    would drag in their unchanged siblings. Everything starts expanded, since
    the whole point is seeing the shape of the change at a glance, and a
    session is small by construction.
    */
    private void addSession() @safe
    {
        uint[string] dirs; // directory path → node index

        uint parentFor(string dir) @safe
        {
            if (dir.length == 0)
                return uint.max;
            if (auto p = dir in dirs)
                return *p;
            const cut = lastSlash(dir);
            FsEntry d = {
                name: cut == size_t.max ? dir : dir[cut + 1 .. $],
                path: dir, isDir: true, openDir: true,
            };
            const idx = data.add(d, parentFor(cut == size_t.max ? "" : dir[0 .. cut]));
            dirs[dir] = idx;
            return idx;
        }

        foreach (i, ref e; session)
        {
            // A removed file lives where it was; everything else where it is.
            const path = e.newPath.length && e.newPath != "/dev/null"
                ? e.newPath : e.oldPath;
            if (path.length == 0 || path == "/dev/null")
                continue;
            const cut = lastSlash(path);
            const st = sessionGitStatus(e.change);
            const b = gitBadge(st);
            FsEntry f = {
                name: text(cut == size_t.max ? path : path[cut + 1 .. $],
                    "  +", e.added, " −", e.removed),
                path: path, gitSt: st, badge: b.letter,
                badgeFg: b.fg, hasBadgeFg: b.letter.length != 0,
                sessionIndex: cast(int) i,
            };
            data.add(f, parentFor(cut == size_t.max ? "" : path[0 .. cut]));
        }
    }

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
                if (!visible(e))
                    continue;
                const isOpen = e.isDir && open.isOpen(e.path);
                e.openDir = isOpen; // the disclosure-state icon (XPL6)
                const idx = data.add(e, parent);
                if (!e.isDir)
                    continue;
                if (childrenVisible || isOpen)
                    addChildren(e.path, idx, childrenVisible && isOpen);
            }
        }

        if (session.length)
            addSession();
        else if (filter.text.length == 0)
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
        palette = themeValue !is null ? themeValue.effectivePalette
            : Palette.init;
        palette.fg[Slot.track] = Color.fromRgb(sbTrack);
        palette.fgAlpha[Slot.track] = 0xFF;
        palette.fg[Slot.thumb] = Color.fromRgb(sbThumb);
        palette.fgAlpha[Slot.thumb] = 0xFF;

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

        // A session tree is always fully expanded (`TVU6`): its whole purpose
        // is showing the shape of the change, and it is small by construction.
        rows = flatten(data, (uint i) @safe
            => session.length != 0 || filter.text.length != 0
                || open.isOpen(data.nodes[i].value.path));
        tv.measureContent(data);
        clamp();
    }

    // The filter pass: depth-first, a dir is added only if its subtree holds a
    // match (broot's tree-as-search-result — everything visible, fully open).
    private bool addFiltered(string dir, uint parent) @system
    {
        bool any;
        foreach (e; listDir(dir))
        {
            if (!visible(e))
                continue;
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
            slot: focused ? Slot.chromeAccent : Slot.gutter,
            textStyle: TextStyle(bold: focused)));
        import std.conv : text;
        const pos = b.add(Widget(kind: WidgetKind.text,
            text: text(rows.length ? sel + 1 : 0, "/", rows.length),
            slot: Slot.gutter));
        const hdr = headerBar(b, [name], null, [pos], focused);

        // The header paints unshifted; the tree shifts left by the
        // horizontal offset (IXB2) and clips to the pane.
        const hx = hOverflows() ? cast(int) hsb.offset : 0;
        Widget hdrCol = Widget(kind: WidgetKind.column, children: [hdr],
            width: SizeSpec.fixed(width));
        auto ht = b.finish(b.add(hdrCol));
        paintGrid(g, pageBg, buildDisplayList(ht, layout(ht),
            palette, pageFg, pageBg));
        auto tb = Builder();
        const tree2 = viewSlice(tb, data, tv,
            (uint i) @safe => filter.text.length != 0 || open.isOpen(data.nodes[i].value.path),
            explorerGlyphs, selBg, hasSelectionBg: true);
        Widget colW = Widget(kind: WidgetKind.column, children: [tree2],
            width: SizeSpec.fixed(width + hx));
        auto wt = tb.finish(tb.add(colW));
        paintGrid(g, pageBg, buildDisplayList(wt, layout(wt),
            palette, pageFg, pageBg),
            -hx, 1, Rect(hx, 0, width - 1, bodyRows));

        // The horizontal bar, one row above the status bar, when live —
        // the SAME component/machine as the vertical bar (IXB2).
        if (hOverflows() && height >= 4)
        {
            import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;

            auto hb = Builder();
            const bar2 = scrollbar(hb, hsb, contentCols, width - 1,
                width - 1, ScrollbarGlyphs('━', '─'));
            auto hbt = hb.finish(bar2);
            paintGrid(g, pageBg, buildDisplayList(hbt, layout(hbt),
                palette, pageFg, pageBg),
                0, height - 2);
        }

        // The status bar pinned to the bottom row (its own one-row pipeline).
        auto sb = Builder();
        const status = sb.add(Widget(kind: WidgetKind.text,
            text: searching ? text("/", query, "▏")
                : text("⏎ open · / filter · H", showHidden ? "✓" : "",
                    " hidden · I", showIgnored ? "✓" : "",
                    " ignored · r refresh · q quit"),
            slot: searching ? Slot.inherit : Slot.gutter));
        const bar = headerBar(sb, [status], null, null);
        Widget barCol = Widget(kind: WidgetKind.column, children: [bar],
            width: SizeSpec.fixed(width));
        auto bt = sb.finish(sb.add(barCol));
        paintGrid(g, pageBg, buildDisplayList(bt, layout(bt),
            palette, pageFg, pageBg),
            0, height > 0 ? height - 1 : 0);

        // Scrollbar in the pane's last column when the tree overflows —
        // the one component (WGT10) over the one machine (STM9), tinted by
        // the palette's track/thumb entries (B-1).
        if (cast(long) rows.length > bodyRows && width >= 2
            && width <= g.cols)
        {
            import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;

            auto vb = Builder();
            const vbar = scrollbar(vb, this.sb.scrolledTo(top), rows.length,
                bodyRows, bodyRows, ScrollbarGlyphs('█', '░'));
            auto vbt = vb.finish(vbar);
            paintGrid(g, pageBg, buildDisplayList(vbt, layout(vbt),
                palette, pageFg, pageBg), width - 1, 1);
        }
    }

    // Returns false to quit the explorer (picked empty = quit for good).
    bool handle(in Event e) @system
    {
        if (searching)
            return handleSearch(e);
        return e.match!(
            (in KeyEvent k) => handleKey(k),
            // A wheel scrolls the VIEW and leaves the cursor where it is —
            // what the document pane, the inspector and every GUI pane
            // already do. This pane moved the selection instead, so the same
            // gesture meant two things in one application (and the GUI's copy
            // of this pane disagreed with the terminal's). The cursor is the
            // reader's place; the wheel is the reader's window.
            (in WheelEvent w) {
                tv.scrollBy(w.dy);
                return true;
            },
            (in PointerEvent p) {
                // The shared precedence (bars grab, rows select, a second
                // click activates) is the component's; only what activation
                // MEANS — open the file / jump the diff — stays here.
                if (tv.pointer(p) == TreeStep.activated)
                    return activate();
                return true;
            },
            (in EndOfInput _) => false,
            _ => true,
        );
    }

    // The entry's root-relative path (for `/`-carrying glob patterns).
    // (`ref const`, not `in`: dip1000 would make the returned slice scope.)
    private const(char)[] relOf(ref const FsEntry e) const @safe pure nothrow @nogc
    {
        const p = e.path;
        if (p.length > root.length + 1 && p[0 .. root.length] == root
            && p[root.length] == '/')
            return p[root.length + 1 .. $];
        return p;
    }

    private static bool globAny(scope const(char)[] name,
        scope const(char)[] rel, scope const(string)[] globs) @safe
    {
        import std.path : globMatch;

        foreach (g; globs)
            if (globMatch(name, g) || globMatch(rel, g))
                return true;
        return false;
    }

    // The one visibility predicate (XPF2, snacks precedence): `include`
    // overrides hidden, ignored, and `exclude`; a dir always passes the
    // include gate (its subtree may contain includes) but still honors
    // hidden/ignored/exclude when it matches none.
    private bool visible(ref const FsEntry e) @safe
    {
        const rel = relOf(e);
        if (includeGlobs.length && globAny(e.name, rel, includeGlobs))
            return true;
        // A dir passes the include gate when a path-carrying include glob
        // descends into it (`build/*.log` keeps `build/` reachable).
        if (includeGlobs.length && e.isDir)
            foreach (g; includeGlobs)
                if (g.length > rel.length + 1 && g[0 .. rel.length] == rel
                    && g[rel.length] == '/')
                    return true;
        if (!showHidden && e.name.length && e.name[0] == '.')
            return false;
        if (!showIgnored && git.map.present
            && git.map.statusOf(e.path, e.isDir) == GitStatus.ignored)
            return false;
        if (excludeGlobs.length && !e.isDir
            && globAny(e.name, rel, excludeGlobs))
            return false;
        return true;
    }

    /// XPF2: runtime visibility toggles (`H` / `I`).
    void toggleHidden() @system
    {
        showHidden = !showHidden;
        rebuild();
    }

    /// ditto
    void toggleIgnored() @system
    {
        showIgnored = !showIgnored;
        rebuild();
    }

    /// XPF3: re-root to the selected dir (a file re-roots to its parent).
    void rerootSel() @system
    {
        if (sel >= cast(long) rows.length)
            return;
        ref const v = data.nodes[rows[cast(size_t) sel].node].value;
        setRoot(v.isDir ? v.path : dirName(v.path));
    }

    /// XPF3: re-root one level up.
    void rerootParent() @system
    {
        const p = dirName(root);
        if (p.length && p != root)
            setRoot(p);
    }

    private void setRoot(string r) @system
    {
        if (r == root)
            return;
        root = r;
        git = GitStatusCache.init; // a new root gets a fresh snapshot
        sel = 0;
        top = 0;
        rebuild();
    }

    /// XPF3: collapse every open dir (the open set resets; the root listing
    /// stays loaded — `expanded` runs one level past `open` as always).
    void closeAll() @system
    {
        open = DisclosureState!string.init;
        sel = 0;
        rebuild();
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
        tv.jumpMatching(dir,
            (uint n) => data.nodes[n].value.gitSt > GitStatus.ignored);
    }

    /// Enter/→ on a dir toggles it; on a file, picks it (`picked` is set and
    /// `false` returned — the host opens it and clears `picked`).
    bool activate() @system
    {
        final switch (treeActivate(tv, data, (uint n) => data.nodes[n].value.path))
        {
            case TreeStep.none:
            case TreeStep.handled:
                return true;
            case TreeStep.rebuild:
                rebuild();
                return true;
            case TreeStep.activated:
                ref const v = data.nodes[rows[cast(size_t) sel].node].value;
                picked = v.path;
                // `TVU6`: a session row names a file in the diff, not a
                // document to load — the workspace jumps the diff pane to it
                // instead of reading it.
                pickedSession = v.sessionIndex;
                return false;
        }
    }

    private bool handleKey(in KeyEvent e) @system
    {
        const st = ltnStep(lantern, e, KeyContext(
            treeFocused: true, treeVisible: true));
        // Escape leaves the pane when nothing is pending; the guide takes it
        // first when a sequence is in flight, which is what makes a mistyped
        // prefix recoverable instead of an exit.
        if (st.kind == LtnStepKind.closed)
            return true;
        if (st.kind != LtnStepKind.execute)
            return e.key != Key.escape;
        return handleCommand(st.cmd.cmd);
    }

    /// The explorer's keys — the ONE table (`KEY1`), dispatched.
    ///
    /// This was hue's third copy of the keyboard policy. Routing it here is
    /// what makes `gg`/`Shift-G` mean the same motion in both panes, and what
    /// gives the tree the key guide without a second implementation of it.
    private bool handleCommand(Command cmd) @system
    {
        final switch (cmd)
        {
            case Command.none:
            case Command.dismiss:
            case Command.inputBackspace:
            case Command.inputAccept:
            case Command.inputCancel:
            case Command.toggleFullscreen:
            case Command.lanternAll:
                break;

            case Command.quit: return false;

            case Command.treeDown:  moveSel(1); break;
            case Command.treeUp:    moveSel(-1); break;
            case Command.treeHome:  selHome(); break;
            case Command.treeEnd:   selEnd(); break;
            case Command.treePageDown: moveSel(bodyRows); break;
            case Command.treePageUp:   moveSel(-bodyRows); break;
            case Command.treeActivate: return activate();
            case Command.treeCollapseOrUp: collapseOrUp(); break;
            case Command.treeFilter:   filterStart(); break;
            case Command.treeNextChange: jumpChange(1); break;
            case Command.treePrevChange: jumpChange(-1); break;
            case Command.treeRefresh:  refreshNow(); break;
            case Command.treeToggleHidden:  toggleHidden(); break;
            case Command.treeToggleIgnored: toggleIgnored(); break;
            case Command.treeReroot:   rerootSel(); break;
            case Command.treeParent:   rerootParent(); break;
            case Command.treeCloseAll: closeAll(); break;

            // The workspace owns the pane split and the viewer owns its own
            // document; a focused tree simply does not answer these. Explicit
            // arms rather than a `default:`, so a new command is a compile
            // error here until someone decides whether the tree answers it.
            case Command.toggleExplorer:
            case Command.toggleInspector:
            case Command.viewDown: case Command.viewUp:
            case Command.viewHome: case Command.viewEnd:
            case Command.viewTop:  case Command.viewBottom:
            case Command.viewPageDown: case Command.viewPageUp:
            case Command.themeNext: case Command.themePrev:
            case Command.fontBigger: case Command.fontSmaller:
            case Command.matchNext: case Command.matchPrev:
            case Command.setNext: case Command.setPrev: case Command.setIndex:
            case Command.toggleView: case Command.copySelection:
            case Command.toggleLineNumbers: case Command.toggleCodeLineNumbers:
            case Command.toggleAnsiCopy: case Command.toggleTableCopy:
            case Command.startSearch: case Command.startGoto:
            case Command.toggleHoverRegions: case Command.cycleHoverPopup:
            case Command.foldToggle: case Command.foldClose: case Command.foldOpen:
            case Command.foldOpenAll: case Command.foldCloseAll: case Command.foldLevel:
            case Command.diffNextFile: case Command.diffPrevFile:
            case Command.diffNextHunk: case Command.diffPrevHunk:
            case Command.diffToggleFile: case Command.diffCollapseAll:
            case Command.diffExpandAll: case Command.diffToggleFormatting:
            case Command.diffToggleLayout: case Command.diffToggleContext:
            case Command.diffToggleGap: case Command.diffToggleStructural:
            case Command.viewScrollLeft: case Command.viewScrollRight:
            case Command.viewScrollHome: case Command.viewScrollEnd:
            case Command.diffStage: case Command.diffUnstage:
            case Command.diffDiscard:
                break;
        }
        return true;
    }

    /// Close the selected directory, else jump to its parent — `h` and `←`.
    /// Public, so the GUI host dispatches here instead of re-implementing it.
    void collapseOrUp() @system
    {
        if (treeCollapseOrUp(tv, data, (uint n) => data.nodes[n].value.path)
            == TreeStep.rebuild)
            rebuild();
    }

    private bool handleSearch(in Event ev) @system
    {
        return ev.match!((in KeyEvent e) {
            if (tv.filterKey(e) == TreeStep.rebuild)
                rebuild();
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
    x.filter = LineEditState("app", true);
    x.rebuild();
    assert(x.rows.length == 2);
    assert(x.data.nodes[x.rows[0].node].value.name == "src");
    assert(x.data.nodes[x.rows[1].node].value.name == "app.d");

    // Enter on the file picks it (ends the session).
    x.sel = 1;
    assert(!x.activate());
    assert(x.picked.canFind("app.d"));
}
@("explorer.pointer.scrollbarGrabIsNotARowClick")
@system
unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    // Enough files to overflow the pane, so the scrollbar exists.
    const root = buildPath(tempDir(), "hue-explorer-sb-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    foreach (i; 0 .. 12)
        write(buildPath(root, text("f", i, ".d")), "int x;\n");

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.width = 50;
    x.height = 8; // bodyRows = 6 < 12 rows → the scrollbar is live
    x.rebuild();
    assert(cast(long) x.rows.length > x.bodyRows);

    // A press on the TRACK (below the thumb) jumps: the selection stays,
    // nothing activates, and the view lands by the STM2 inverse mapping.
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(49, 5)))));
    assert(x.sb.dragging);
    assert(x.sel == 0, "a scrollbar press never selects a row");
    assert(x.top > 0, "a track press jumped to the pointer");

    // The drag owns the pointer even off the column — still no row clicks.
    const grabbed = x.top;
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(20, 3)))));
    assert(x.top < grabbed && x.sel == 0, "the drag kept scrolling off-column");
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(20, 3)))));
    assert(!x.sb.dragging);

    // A press ON the handle grabs it in place — no jump — and the drag
    // then moves it relative to the grab point.
    import sparkles.ui.state : scrollbarThumb;
    const t0 = scrollbarThumb(x.rows.length, x.bodyRows, x.top, x.bodyRows);
    const inThumb = cast(int) t0.start + (t0.extent > 1 ? 1 : 0);
    const before = x.top;
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(49, inThumb + 1)))));
    assert(x.top == before, "a click on the handle must not move it");
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(49, inThumb + 2)))));
    assert(x.top > before, "the drag moved the thumb relative to the grab");
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(49, inThumb + 2)))));

    // Off the scrollbar, a press is still a row click.
    const want = x.top + 1;
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(5, 2)))));
    assert(x.sel == want, text(x.sel, " vs ", want));
}

@("explorer.wheel.scrollsTheViewNotTheCursor")
@system
unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.input : linesPerNotch, WheelEvent;
    import sparkles.syntax : builtinDark, LabelSet;

    const root = buildPath(tempDir(), "hue-explorer-wheel-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    foreach (i; 0 .. 12)
        write(buildPath(root, text("f", i, ".d")), "int x;\n");

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.width = 50;
    x.height = 8; // bodyRows = 6 < 12 rows → there is somewhere to scroll
    x.rebuild();

    // A wheel notch moves the VIEW and leaves the cursor alone — the same
    // meaning the document pane, the inspector and both GUI panes give it.
    // This pane used to move the selection instead.
    assert(x.handle(Event(WheelEvent(dy: linesPerNotch))));
    assert(x.top == linesPerNotch, text("top ", x.top));
    assert(x.sel == 0, "the wheel is the window, not the cursor");

    // …and it clamps at both ends rather than running past them.
    assert(x.handle(Event(WheelEvent(dy: -linesPerNotch * 10))));
    assert(x.top == 0 && x.sel == 0);
    assert(x.handle(Event(WheelEvent(dy: linesPerNotch * 100))));
    assert(x.top == cast(long) x.rows.length - x.bodyRows);
}

@("explorer.pointer.horizontalBarScrollsClippedLabels")
@system
unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;

    const root = buildPath(tempDir(), "hue-explorer-hbar-test");
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "a-very-long-file-name-that-overflows-the-pane.d"),
        "int x;\n");

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.width = 20; // narrower than the label
    x.height = 8;
    x.rebuild();
    assert(x.hOverflows(), text(x.contentCols, " vs ", x.width));

    // A press on the horizontal bar's row grabs it (never a row click);
    // dragging right scrolls the columns; release ends the grab.
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.press, pos: Point(2, cast(int) x.height - 2)))));
    assert(x.hsb.dragging);
    assert(x.sel == 0, "the bar row is not a tree row");
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.drag, pos: Point(12, cast(int) x.height - 2)))));
    assert(x.hsb.offset > 0, "the drag scrolled the columns");
    assert(x.handle(Event(PointerEvent(button: PointerButton.left,
        action: PointerAction.release, pos: Point(12, cast(int) x.height - 2)))));
    assert(!x.hsb.dragging);
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

@("explorer.togglesRerootAndCloseAll")
@system
unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;
    import git_status : GitStatus, GitStatusMap;

    // No git needed: the ignored toggle is driven by a hand-built snapshot.
    const root = buildPath(tempDir(), "hue-explorer-toggles-test");
    if (root.exists)
        rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "src"));
    mkdirRecurse(buildPath(root, "build"));
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, ".hidden.conf"), "");
    write(buildPath(root, "keep.d"), "int k;\n");
    write(buildPath(root, "src", "app.d"), "void main() {}\n");
    write(buildPath(root, "build", "out.o"), "");

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.pageFg = fallbackFg;
    x.pageBg = fallbackBg;
    x.width = 44;
    x.height = 12;
    // The snapshot marks build/ ignored (as `!! build/` would).
    x.git.seed(GitStatusMap(["build": GitStatus.ignored], null, root, true));
    x.rebuild();

    bool listed(string name)
    {
        foreach (ref const r; x.rows)
            if (x.data.nodes[r.node].value.name == name)
                return true;
        return false;
    }

    // Defaults: dotfiles hidden, ignored listed (dimmed).
    assert(!listed(".hidden.conf") && listed("build") && listed("keep.d"));

    // XPF2: the toggles flip visibility (state is in the status bar).
    x.toggleIgnored();
    assert(!listed("build"));
    x.toggleHidden();
    assert(listed(".hidden.conf"));
    x.toggleHidden();
    x.toggleIgnored();
    assert(listed("build") && !listed(".hidden.conf"));

    // XPF3: re-root into src/ and back out; the fresh cache clears the map.
    foreach (i, ref const r; x.rows)
        if (x.data.nodes[r.node].value.name == "src")
            x.sel = cast(long) i;
    x.rerootSel();
    assert(x.root.canFind("src"));
    assert(listed("app.d") && !listed("keep.d"));
    x.rerootParent();
    assert(x.root == root);
    assert(listed("keep.d"));

    // XPF3: close-all resets the open set (the root listing remains).
    x.open = x.open.opened(buildPath(root, "src"));
    x.rebuild();
    assert(listed("app.d"));
    x.closeAll();
    assert(!listed("app.d") && listed("src"));

    // reveal() outside the root re-roots outward (XPF3 × XPL4).
    const outside = buildPath(tempDir(),
        "hue-explorer-toggles-test-outside");
    mkdirRecurse(outside);
    scope (exit) rmdirRecurse(outside);
    write(buildPath(outside, "elsewhere.d"), "int e;\n");
    x.reveal(buildPath(outside, "elsewhere.d"));
    assert(x.root == outside);
    assert(listed("elsewhere.d"));
}

@("explorer.globs.snacksPrecedence")
@system
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import sparkles.syntax : builtinDark, LabelSet;
    import git_status : GitStatus, GitStatusMap;

    const root = buildPath(tempDir(), "hue-explorer-globs-test");
    if (root.exists)
        rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "build"));
    // The async git-status refresh may hold a transient `.git/index.lock`
    // while teardown iterates — retry once after it settles.
    scope (exit)
    {
        import core.thread : Thread;
        import core.time : msecs;
        import std.exception : collectException;

        if (collectException(rmdirRecurse(root)) !is null)
        {
            Thread.sleep(200.msecs);
            collectException(rmdirRecurse(root));
        }
    }
    write(buildPath(root, ".env"), "");
    write(buildPath(root, "keep.d"), "int k;\n");
    write(buildPath(root, "noise.log"), "");
    write(buildPath(root, "build", "keep.log"), "");
    // A REAL repo whose .gitignore matches the hand-seeded map below:
    // rebuild() kicks the async status refresh, and when it lands mid-test
    // it must CONFIRM the seeded state, not clobber it (a non-repo root
    // yields an empty map and made this test flaky).
    {
        import std.process : execute;

        write(buildPath(root, ".gitignore"), "build/\n");
        try
            execute(["git", "init", "-q", root]);
        catch (Exception)
        {
        }
    }

    static immutable Theme dark = builtinDark;
    ExplorerTui x;
    x.root = root;
    x.themeValue = &dark;
    x.theme = resolveTheme(dark, LabelSet.standard());
    x.pageFg = fallbackFg;
    x.pageBg = fallbackBg;
    x.width = 44;
    x.height = 12;
    x.git.seed(GitStatusMap(["build": GitStatus.ignored], null, root, true));
    x.open = x.open.opened(buildPath(root, "build"));

    bool listed(string name)
    {
        foreach (ref const r; x.rows)
            if (x.data.nodes[r.node].value.name == name)
                return true;
        return false;
    }

    // Exclude hides matches (by name or root-relative path).
    x.excludeGlobs = ["*.log"];
    x.rebuild();
    assert(listed("keep.d") && !listed("noise.log") && !listed("keep.log"));

    // Include overrides exclude…
    x.includeGlobs = ["noise.*"];
    x.rebuild();
    assert(listed("noise.log") && !listed("keep.log"));

    // …and hidden…
    x.includeGlobs = [".env"];
    x.rebuild();
    assert(listed(".env"));

    // …and ignored (build/ is git-ignored and the toggle is off).
    x.showIgnored = false;
    x.includeGlobs = ["build/*.log"];
    x.excludeGlobs = null;
    x.rebuild();
    assert(listed("keep.log"), "include overrides ignored");
    x.includeGlobs = null;
    x.rebuild();
    assert(!listed("build"), "the ignored dir hides without the include");
}

@("explorer.sessionTree.pathsBecomeATreeWithBadgesAndCounts")
@system unittest
{
    import diff_session : FileChange, SessionEntry;
import keymap : Command, KeyContext;
import lantern : LanternState, ltnStep = step, ltnTick = tick,
    untilShown, LtnStepKind = StepKind;

    // `TVU6`: the tree is built from the session's paths alone — no
    // filesystem is touched, which is the property that lets a diff of files
    // that no longer exist (or never did, on a removed side) still list.
    ExplorerTui x;
    x.root = "/nonexistent-on-purpose";
    x.session = [
        SessionEntry(oldPath: "src/a.d", newPath: "src/a.d", display: "src/a.d",
            change: FileChange.modified, added: 3, removed: 1),
        SessionEntry(oldPath: "/dev/null", newPath: "src/deep/b.d",
            display: "src/deep/b.d", change: FileChange.added, added: 7),
        SessionEntry(oldPath: "gone.d", newPath: "/dev/null",
            display: "gone.d", change: FileChange.removed, removed: 4),
    ];
    x.rebuild();

    string[] labels;
    foreach (ref n; x.data.nodes)
        labels ~= n.value.name.idup;
    // Directories are synthesized from the paths, shared between the files
    // under them — `src` appears once, with `deep` nested inside it.
    assert(labels.length == 5, text(labels)); // 2 synthesized dirs + 3 files
    assert(labels[0] == "src");
    assert(labels[1] == "a.d  +3 −1");
    assert(labels[2] == "deep" && labels[3] == "b.d  +7 −0");
    // A removed file lives at the path it had, at the root here.
    assert(labels[4] == "gone.d  +0 −4");

    // Badges use the explorer's own git-status vocabulary, so the tree and
    // the diff headers read the same.
    string[] badges;
    foreach (ref n; x.data.nodes)
        if (!n.value.isDir)
            badges ~= n.value.badge;
    assert(badges == ["M", "A", "D"], text(badges));

    // Every leaf carries the index that jumps the diff pane; the synthesized
    // directories carry none.
    foreach (ref n; x.data.nodes)
        assert((n.value.sessionIndex >= 0) == !n.value.isDir);

    // Everything starts expanded: the shape of the change is the point.
    assert(x.rows.length == x.data.nodes.length, "no row is hidden");
}
