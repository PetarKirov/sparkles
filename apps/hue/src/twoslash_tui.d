// `hue --twoslash` in an interactive terminal — the TUI counterpart of the raylib
// GUI, built on `sparkles:tui` (raw mode, SGR-1006 mouse, retained-grid diff loop)
// and the shared `sparkles:ui` paint model (via `sparkles:ui-tui`'s GridCanvas).
//
// The whole document — code lines as resolved-color spans, highlight tints,
// error undercurls, and below-line meta blocks — is ONE widget tree
// (viewTwoslashDocument), painted with a scroll offset; only the selected
// token's hover popup composites on top per frame. Selection: Tab / arrows
// cycle the hover tokens, a mouse click picks one (hit-tested against the
// tokens' identity-channel rects).
//
// Posix-only (the raw-mode loop is). Reached from `runTwoslashMode` when stdout is
// an interactive tty and neither `--gui` nor `--html` was given; a pipe/redirect
// falls back to the non-interactive ANSI overlay.
module twoslash_tui;

version (Posix):

import sparkles.tui.app : runApp;
import sparkles.tui.cell : CellStyle, Grid;
import sparkles.tui.input : EndOfInput, Event, Key, KeyEvent, match,
    PointerAction, PointerEvent, WheelEvent;
import sparkles.tui.terminal : TerminalOptions;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_caps : TermSize;

import sparkles.twoslash.overlay : planTwoslash, TwoslashPlan;
import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn;
import sparkles.twoslash.render_widgets : viewHoverPopup, viewTwoslashDocument;

import sparkles.syntax : HighlightEvent, LabelSet,
    ResolvedTheme, RgbColor, toRgb;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.syntax.ts.highlighter : highlightInjected;
import sparkles.twoslash.ingest : loadTwoslashFile;
import source_set : SourceSet;

import sparkles.ui.canvas : DrawOp;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : selectionRects;
import sparkles.ui.style : defaultTwoslashPalette, Palette,
    schemeForBackground, Slot;
import sparkles.ui.widget : WidgetTree;

import sparkles.base.term_color : Color;

import sparkles.ui_tui : paintGrid;

private enum padCols = 1; // left margin, matching the GUI's twoslashPadCells

/**
Runs the interactive terminal twoslash overlay for `tw` (its `code` already
highlighted into `events`) until the user quits. Returns 0. The `tw`/`theme`
data is borrowed for the session (the caller must keep it alive across the call).
*/
int runTuiTwoslash(
    string title,
    in TwoslashReturn tw,
    const(HighlightEvent)[] events,
    in ResolvedTheme theme,
    ref TsConfigCache cache,
    SourceSet* set = null,
) @system
{
    auto app = TwoslashTui(&tw, theme);
    app.name = title;
    app.set = set;
    app.cache = &cache;
    app.events = events;
    if (set !is null && !set.empty)
        app.summary = set.current.summary;
    app.rebuildView();

    runApp(&app.render, &app.handle);
    return 0;
}

/**
Renders a single TUI frame (no terminal, no input) to a self-contained styled
`<pre>` HTML string — the QA-capture path. A headless browser screenshots it, so
the TUI mode is captured uniformly with the HTML mode. `selIdx >= 0` pre-selects
that hover token so its popup composites into the frame; `-1` is the resting
frame.
*/
string captureTuiFrameHtml(
    string title,
    in TwoslashReturn tw,
    const(HighlightEvent)[] events,
    in ResolvedTheme theme,
    ref TsConfigCache cache,
    int cols,
    int rows,
    int selIdx,
) @system
{
    auto app = TwoslashTui(&tw, theme);
    app.cache = &cache;
    app.events = events;
    app.rebuildView();
    app.selIdx = selIdx;

    Grid g;
    g.resize(cast(ushort) cols, cast(ushort) rows);
    app.render(g, TermSize(cast(ushort) cols, cast(ushort) rows));
    return gridToHtml(g, app.pageFg, app.pageBg);
}

/// Serializes a rendered `Grid` to a styled `<pre>`: each run of same-style cells
/// becomes one `<span>` with inline `color`/`background`/`text-decoration` (the
/// undercurl maps to `text-decoration: underline wavy <color>`).
private string gridToHtml(in Grid g, RgbColor pageFg, RgbColor pageBg) @system
{
    import std.array : appender;
    import sparkles.base.term_style : UnderlineStyle;

    auto sb = appender!string;

    void hex(RgbColor c)
    {
        static immutable d = "0123456789abcdef";
        foreach (v; [c.r, c.g, c.b])
        {
            sb ~= d[v >> 4];
            sb ~= d[v & 0x0F];
        }
    }

    void esc(scope const(char)[] s)
    {
        foreach (ch; s)
            switch (ch)
            {
                case '<': sb ~= "&lt;"; break;
                case '>': sb ~= "&gt;"; break;
                case '&': sb ~= "&amp;"; break;
                default: sb ~= ch; break;
            }
    }

    sb ~= `<pre style="margin:0;padding:10px;line-height:1.3;`
        ~ `font:15px ui-monospace,Menlo,Consolas,monospace;background:#`;
    hex(pageBg);
    sb ~= ";color:#";
    hex(pageFg);
    sb ~= `">`;

    foreach (ushort y; 0 .. g.rows)
    {
        ushort x = 0;
        while (x < g.cols)
        {
            const st = g[x, y].style;
            sb ~= `<span style="color:#`;
            hex(toRgb(st.fg, pageFg));
            sb ~= ";background:#";
            hex(toRgb(st.bg, pageBg));
            if (st.underline != UnderlineStyle.none)
            {
                sb ~= ";text-decoration:underline ";
                sb ~= st.underline == UnderlineStyle.curly ? "wavy #" : "solid #";
                hex(toRgb(st.underlineColor, pageFg));
            }
            sb ~= `">`;
            for (; x < g.cols; ++x)
            {
                const c = g[x, y];
                if (c.width == 0)
                    continue; // wide-glyph continuation carries no bytes
                if (c.style != st)
                    break;
                esc(c.grapheme);
            }
            sb ~= "</span>";
        }
        sb ~= '\n';
    }
    sb ~= "</pre>";
    return sb[];
}

/// The interactive overlay's state + frame painter. One instance per session; its
/// `render`/`handle` are handed to `sparkles.tui.runApp`.
private struct TwoslashTui
{
    // The current payload, by pointer so navigating a set can rebind it (`Node[]`
    // is mutable, so a const payload cannot be copied into a mutable field).
    // Borrowed slices (code/nodes) — the caller keeps them alive.
    const(TwoslashReturn)* twPtr;
    const(ResolvedTheme) theme;
    TwoslashPlan plan;
    Palette pal;
    RgbColor pageFg, pageBg;
    const(HighlightEvent)[] events;

    // The whole document as one laid-out widget tree (viewTwoslashDocument),
    // rebuilt per payload; painted each frame with the scroll offset.
    WidgetTree tree;
    Frame[] frames;
    DrawOp[] ops;
    size_t[] selectable;  // node indices with a hover popup, in plan order
    Rect[] targetRects;   // per-selectable token rect in DOCUMENT cell coords

    int scrollRow;
    int selIdx = -1;      // index into `selectable`, or -1 for none

    // Document-set navigation (`GNV1`/`GNV2`): `[`/`]` walk the set, the status
    // bar names the current entry. Null when viewing a single payload.
    SourceSet* set;
    TsConfigCache* cache;
    string name;
    string summary;

    /// The payload being viewed.
    ref const(TwoslashReturn) tw() const scope return => *twPtr;

    this(const(TwoslashReturn)* t, in ResolvedTheme th) @system
    {
        twPtr = t;
        theme = th;
        plan = planTwoslash(*t);
        pageFg = toRgb(th.defaults.fg, RgbColor(0xcd, 0xd6, 0xf4));
        pageBg = toRgb(th.defaults.bg, RgbColor(0x1e, 0x1e, 0x2e));
        // Pick the popup surface/docs shade to match the theme (dark bg ⇒ dark
        // surface), so the signature stays readable — the QA-surfaced contrast fix.
        pal = defaultTwoslashPalette(schemeForBackground(pageBg));
        foreach (ref const d; plan.inlineDecorations)
            if (d.kind == NodeType.hover)
                selectable ~= d.node;
    }

    /// Rebuilds the document tree + its derived geometry (per payload/theme;
    /// call after `events`/`cache` are set). Token rects come from the
    /// identity channel, so the pointer hit-test needs no per-frame capture.
    void rebuildView() @system
    {
        tree = viewTwoslashDocument(tw, events, &theme, pageFg, cache);
        frames = layout(tree);
        ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);
        targetRects = new Rect[](selectable.length);
        foreach (i, ni; selectable)
        {
            const n = tw.nodes[ni];
            auto rs = selectionRects(tree, frames, n.start, n.start + n.length);
            if (rs.length)
                targetRects[i] = rs[0];
        }
    }

    /// The cell style for a syntax label: the theme's `StyleSpec` (a `TermStyle`,
    /// Paints one whole frame into `grid`: the document's precomputed ops at
    /// the scroll offset, then the selected token's popup composited on top.
    void render(ref Grid grid, TermSize sz) @system
    {
        CellStyle pageStyle;
        pageStyle.fg = Color.fromRgb(pageFg);
        pageStyle.bg = Color.fromRgb(pageBg);
        grid.clearTo(pageStyle);

        paintGrid(grid, pageBg, ops, padCols, -scrollRow);

        if (selIdx >= 0 && selIdx < cast(int) targetRects.length)
        {
            const r = targetRects[selIdx];
            paintTree(grid, viewHoverPopup(tw, selectable[selIdx]),
                padCols + r.x, r.y - scrollRow + 1);
        }

        drawStatus(grid);
    }

    /// Lays out `tree` and paints it at `(ox, oy)`; returns its height in rows.
    private int paintTree(ref Grid grid, WidgetTree tree, int ox, int oy) @system
    {
        auto frames = layout(tree);
        auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);
        paintGrid(grid, pageBg, ops, ox, oy);
        return frames[tree.root].rect.height;
    }

    /// A one-line help/status bar on the bottom row (inverse of the page colors).
    private void drawStatus(ref Grid grid) @system
    {
        if (grid.rows == 0)
            return;
        CellStyle st;
        st.fg = Color.fromRgb(pageBg);
        st.bg = Color.fromRgb(pageFg);
        const y = cast(ushort)(grid.rows - 1);
        grid.fill(0, y, grid.cols, st);
        grid.putText(0, y, " Tab/→ next  ← prev  ↑↓ scroll  click: select  q: quit ", st);

        // With a document set, name the current entry and its position on the
        // right of the same bar (`GNV2`).
        if (set !is null && !set.empty)
        {
            import std.conv : text;

            const right = text(name, "  ", summary, "  ", set.index + 1, "/", set.length,
                "  [ ] prev/next ");
            if (right.length + 2 < grid.cols)
                grid.putText(cast(ushort)(grid.cols - right.length), y, right, st);
        }
    }

    /// Loads the set's currently-selected payload in place (`GNV1`): re-read,
    /// re-highlight, re-plan. A payload that fails to load leaves the current one.
    private bool loadSelected() @system
    {
        if (set is null || set.empty || cache is null)
            return false;
        const entry = set.current;
        auto res = loadTwoslashFile(entry.path);
        if (res.hasError)
            return false;

        auto owned = new TwoslashReturn;
        *owned = res.value;

        SmallBuffer!HighlightEvent ev;
        if (highlightInjected(*cache, "typescript", owned.code, ev).hasError)
            ev ~= HighlightEvent.sourceSpan(0, owned.code.length);

        twPtr = owned;
        plan = planTwoslash(*owned);
        events = ev[].dup;

        selectable = null;
        foreach (ref const d; plan.inlineDecorations)
            if (d.kind == NodeType.hover)
                selectable ~= d.node;
        rebuildView();

        name = entry.name;
        summary = entry.summary;
        scrollRow = 0;   // a new document starts at the top (`GNV3`)
        selIdx = -1;
        return true;
    }

    /// Handles one input event; returns `false` to quit.
    bool handle(in Event ev) @system
    {
        return ev.match!(
            (in KeyEvent k) => handleKey(k),
            (in PointerEvent p) { handlePointer(p); return true; },
            (in WheelEvent w) { scroll(w.dy); return true; },
            (in EndOfInput _) => false,
            _ => true,
        );
    }

    private void scroll(int dy) scope
    {
        if (dy < 0 && scrollRow > 0)
            --scrollRow;
        else if (dy > 0)
            ++scrollRow;
    }

    private bool handleKey(in KeyEvent ev) scope
    {
        switch (ev.key)
        {
            case Key.escape:
                return false;
            case Key.char_:
                if (ev.ch == 'q')
                    return false;
                // `[` / `]` walk the document set (`GNV1`).
                if ((ev.ch == '[' || ev.ch == ']') && set !is null && !set.empty)
                    if (set.move(ev.ch == '[' ? -1 : 1))
                        loadSelected();
                break;
            case Key.tab:
                cycle(ev.mods.shift ? -1 : 1);
                break;
            case Key.right:
                cycle(1);
                break;
            case Key.left:
                cycle(-1);
                break;
            case Key.up:
                if (scrollRow > 0)
                    --scrollRow;
                break;
            case Key.down:
                ++scrollRow;
                break;
            case Key.pageUp:
                scrollRow = scrollRow > 10 ? scrollRow - 10 : 0;
                break;
            case Key.pageDown:
                scrollRow += 10;
                break;
            default:
                break;
        }
        return true;
    }

    private void handlePointer(in PointerEvent ev) scope
    {
        if (ev.action != PointerAction.press)
            return;
        // The decoder delivers 0-based screen cells; the rects are document
        // cells — shift by the left pad and the scroll offset.
        const p = Point(ev.pos.x - padCols, ev.pos.y + scrollRow);
        foreach (i, ref const rect; targetRects)
            if (rect.contains(p))
            {
                selIdx = cast(int) i;
                return;
            }
    }

    /// Advances the selection by `step` (wrapping); a no-op with no hover tokens.
    private void cycle(int step) scope
    {
        if (selectable.length == 0)
            return;
        const n = cast(int) selectable.length;
        selIdx = selIdx < 0
            ? (step > 0 ? 0 : n - 1)
            : ((selIdx + step) % n + n) % n;
    }

}
