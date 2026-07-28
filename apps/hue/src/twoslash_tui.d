// `hue --twoslash` in an interactive terminal — the TUI counterpart of the raylib
// GUI, built on `sparkles:tui` (raw mode, SGR-1006 mouse, retained-grid diff loop)
// and the shared `sparkles:ui` paint model (via `tui_canvas.GridCanvas`).
//
// The code is rendered directly into the cell grid with its syntax-theme colors
// (per-token, not a widget concern); the twoslash overlay — highlight tints, error
// undercurls, below-line meta blocks, and the selected token's hover popup — is
// composited on top through the ui pipeline. Selection: Tab / arrows cycle the
// hover tokens, a mouse click picks one, its popup composites over the code.
//
// Posix-only (the raw-mode loop is). Reached from `runTwoslashMode` when stdout is
// an interactive tty and neither `--gui` nor `--html` was given; a pipe/redirect
// falls back to the non-interactive ANSI overlay.
module twoslash_tui;

version (Posix):

import sparkles.tui.app : runApp;
import sparkles.tui.cell : CellStyle, Grid;
import sparkles.tui.input : Event, EventKind, Key, MouseAction;
import sparkles.tui.terminal : TerminalOptions;

import sparkles.base.text.width : codepointWidth;
import sparkles.core_cli.term_caps : TermSize;

import sparkles.twoslash.overlay : errIsWarning, InlineDecoration, planTwoslash, TwoslashPlan;
import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn;
import sparkles.twoslash.render_widgets : viewBelowBlock, viewHoverPopup;

import sparkles.syntax : byStyledLine, HighlightEvent, LabelId, LabelSet,
    ResolvedTheme, RgbColor, StyledLineSpan, toRgb;
import sparkles.syntax.ts.injection : TsConfigCache;

import sparkles.ui.canvas : LineStyle;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.geometry : Point, Rect, Size;
import sparkles.ui.layout : layout;
import sparkles.ui.style : defaultTwoslashPalette, Palette, resolveSlot,
    schemeForBackground, Slot, Visual;
import sparkles.ui.widget : WidgetTree;

import sparkles.base.term_color : Color;

import tui_canvas : GridCanvas, paintGrid;

private enum padCols = 1; // left margin, matching the GUI's twoslashPadCells

/// A styled run within one source line (absolute byte offsets into `code`).
private struct Run
{
    size_t start, end;
    LabelId label;
}

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
) @system
{
    auto app = TwoslashTui(tw, theme);

    // Per-line styled runs (theme colors), materialized once — the code is static.
    foreach (ls; byStyledLine(tw.code, events))
        app.runsByLine[ls.line] ~= Run(ls.span.start, ls.span.end, ls.span.label);

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
    auto app = TwoslashTui(tw, theme);
    foreach (ls; byStyledLine(tw.code, events))
        app.runsByLine[ls.line] ~= Run(ls.span.start, ls.span.end, ls.span.label);
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
    const(TwoslashReturn) tw; // borrowed slices (code/nodes) — caller keeps them alive
    const(ResolvedTheme) theme;
    TwoslashPlan plan;
    Palette pal;
    RgbColor pageFg, pageBg;
    size_t lineTotal;

    Run[][] runsByLine;
    size_t[] selectable;  // node indices with a hover popup, in plan order
    Rect[] targetRects;   // this frame's on-screen rect per selectable (for the mouse)

    int scrollRow;
    int selIdx = -1;      // index into `selectable`, or -1 for none

    this(in TwoslashReturn t, in ResolvedTheme th) @system
    {
        tw = t;
        theme = th;
        plan = planTwoslash(t);
        pageFg = toRgb(th.defaults.fg, RgbColor(0xcd, 0xd6, 0xf4));
        pageBg = toRgb(th.defaults.bg, RgbColor(0x1e, 0x1e, 0x2e));
        // Pick the popup surface/docs shade to match the theme (dark bg ⇒ dark
        // surface), so the signature stays readable — the QA-surfaced contrast fix.
        pal = defaultTwoslashPalette(schemeForBackground(pageBg));
        lineTotal = 1;
        foreach (c; t.code)
            if (c == '\n')
                ++lineTotal;
        runsByLine = new Run[][](lineTotal);
        foreach (ref const d; plan.inlineDecorations)
            if (d.kind == NodeType.hover)
                selectable ~= d.node;
    }

    /// The cell style for a syntax label: the theme's `StyleSpec` (a `TermStyle`,
    /// same as `CellStyle`) with unset fore/background resolved to the page colors.
    private CellStyle codeStyle(LabelId label) const scope
    {
        CellStyle st = theme[label];
        if (!st.fg.isSet)
            st.fg = Color.fromRgb(pageFg);
        if (!st.bg.isSet)
            st.bg = Color.fromRgb(pageBg);
        return st;
    }

    /// Display-column width of `code[a .. b]`.
    private int spanCols(size_t a, size_t b) const scope
    {
        import std.utf : byDchar;

        int cols;
        foreach (dchar cp; tw.code[a .. b].byDchar)
            cols += codepointWidth(cp) < 0 ? 1 : codepointWidth(cp);
        return cols;
    }

    /// Paints one whole frame into `grid`.
    void render(ref Grid grid, TermSize sz) @system
    {
        const code = tw.code;
        CellStyle pageStyle;
        pageStyle.fg = Color.fromRgb(pageFg);
        pageStyle.bg = Color.fromRgb(pageBg);
        grid.clearTo(pageStyle);

        targetRects.length = 0;
        Rect selRect;
        bool haveSel;

        const errVis = resolveSlot(pal, Slot.error, pageFg, pageBg);
        const warnVis = resolveSlot(pal, Slot.warn, pageFg, pageBg);
        const hlVis = resolveSlot(pal, Slot.highlight, pageFg, pageBg);
        auto canvas = GridCanvas(&grid, pageBg);

        int y = -scrollRow;
        foreach (line; 0 .. lineTotal)
        {
            // 1. Code runs (theme-colored) directly into the grid.
            if (y >= 0 && y < grid.rows)
            {
                int x = padCols;
                foreach (ref const r; runsByLine[line])
                {
                    if (r.end <= r.start || x >= grid.cols)
                        continue;
                    x = grid.putText(cast(ushort) x, cast(ushort) y,
                        code[r.start .. r.end], codeStyle(r.label));
                }
            }

            // 2. Inline decorations on this line: tint / undercurl / hover rects.
            foreach (ref const d; plan.inlineDecorations)
            {
                if (d.line != line)
                    continue;
                const dx = padCols + cast(int) d.character;
                const dcols = spanCols(d.start, d.end);
                const rect = Rect(dx, y, dcols, 1);
                final switch (d.kind)
                {
                    case NodeType.highlight:
                        canvas.fillRect(rect, hlVis);
                        break;
                    case NodeType.error:
                        canvas.line(Point(dx, y), Point(dx + dcols, y),
                            errIsWarning(tw.nodes[d.node].level) ? warnVis : errVis,
                            LineStyle.wavy);
                        break;
                    case NodeType.hover:
                        const s = indexOfSelectable(d.node);
                        if (s >= 0)
                        {
                            if (targetRects.length <= s)
                                targetRects.length = s + 1;
                            targetRects[s] = rect;
                            if (s == selIdx)
                            {
                                selRect = rect;
                                haveSel = true;
                            }
                        }
                        break;
                    case NodeType.query:
                    case NodeType.completion:
                    case NodeType.tag:
                        break;
                }
            }
            ++y;

            // 3. Below-line meta blocks (error message, ^?, completions, @tag).
            foreach (ref const b; plan.belowBlocks)
                if (b.line == line)
                    y += paintTree(grid, viewBelowBlock(tw, b.node), padCols, y);
        }

        // 4. The selected hover token's popup, composited last (on top of code).
        if (haveSel)
            paintTree(grid, viewHoverPopup(tw, selectable[selIdx]),
                selRect.x, selRect.y + 1);

        drawStatus(grid);
    }

    /// Lays out `tree` and paints it at `(ox, oy)`; returns its height in rows.
    private int paintTree(ref Grid grid, WidgetTree tree, int ox, int oy) @system
    {
        auto frames = layout(tree);
        auto ops = buildDisplayList(tree, frames, pal, pageFg, pageBg);
        paintGrid(grid, pageBg, ops, ox, oy);
        return frames[tree.root].rect.h;
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

    /// Handles one input event; returns `false` to quit.
    bool handle(in Event ev) @system
    {
        final switch (ev.kind)
        {
            case EventKind.key:
                return handleKey(ev);
            case EventKind.mouse:
                handleMouse(ev);
                return true;
            case EventKind.resize:
            case EventKind.none:
                return true;
            case EventKind.eof:
                return false;
        }
    }

    private bool handleKey(in Event ev) scope
    {
        switch (ev.key)
        {
            case Key.escape:
                return false;
            case Key.char_:
                if (ev.ch == 'q')
                    return false;
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

    private void handleMouse(in Event ev) scope
    {
        if (ev.action == MouseAction.wheelUp)
        {
            if (scrollRow > 0)
                --scrollRow;
            return;
        }
        if (ev.action == MouseAction.wheelDown)
        {
            ++scrollRow;
            return;
        }
        if (ev.action != MouseAction.press)
            return;
        // SGR mouse is 1-based; the grid is 0-based.
        const px = cast(int) ev.mouse.col - 1, py = cast(int) ev.mouse.row - 1;
        foreach (i, ref const rect; targetRects)
            if (rect.contains(Point(px, py)))
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

    private int indexOfSelectable(size_t node) const scope
    {
        foreach (i, s; selectable)
            if (s == node)
                return cast(int) i;
        return -1;
    }
}
