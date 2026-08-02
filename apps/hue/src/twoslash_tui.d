// The headless twoslash TUI-frame capture (`HUE_TWOSLASH_TUI_CAPTURE`) — the
// QA harness renders one frame to a styled `<pre>` for uniform screenshots.
// The interactive twoslash TUI lives in the `workspace` viewer pane now
// (`PreviewTui` hosts twoslash documents); this module keeps only the
// capture renderer.
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
    app.viewCols = cols - padCols; // the room a `^?` line has (`SIG2`)
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

    TsConfigCache* cache; // query-signature re-highlighting (may be null)

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

    /// The cells the document view has, or 0 for unbounded — a `^?` query
    /// signature breaks inside it rather than past the right edge.
    int viewCols;

    /// Rebuilds the document tree + its derived geometry (per payload/theme;
    /// call after `events`/`cache` are set). Token rects come from the
    /// identity channel, so the pointer hit-test needs no per-frame capture.
    void rebuildView() @system
    {
        tree = viewTwoslashDocument(tw, events, &theme, pageFg, cache, viewCols);
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

    }

}
