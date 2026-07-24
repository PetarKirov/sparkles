// hue's full-screen terminal viewer — the interactive TUI port of the GUI, painted
// into alt-screen cells (tui.md T1). It reuses the GUI's raylib-free layout
// (`gui_preview.layoutPreview` / `buildRawPlines` → the wrapped `PreviewLine[]`)
// and paints it with the shared terminal painter (`preview_ansi`), so the same
// model drives the terminal and the GPU window ("one model, two painters").
//
// This milestone (T1) covers scrolling over the reused layout, a raw/preview
// toggle, live theme cycling, and reflow on terminal resize. Mouse + a cell
// scrollbar (T2), selection → OSC 52 (T3), and incremental search (T4) build on
// it. Posix-only (raw termios via tui_input); Windows degrades to the
// non-interactive preview emit upstream.
module tui;

version (Posix):

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : Color;
import sparkles.base.term_control : CtlSeq;
import sparkles.base.term_style : TermStyle, writeStyleTransition;
import sparkles.base.text.writers : writeInteger;

import sparkles.syntax : ColorDepth, HighlightEvent, LabelSet, ResolvedTheme,
    resolveTheme, RgbColor, Theme, toRgb;

import sparkles.core_cli.term_caps : StdStream, terminalSize;

import gui_preview : buildRawPlines, layoutPreview, PreviewLine, PreviewModel,
    quoteBarColors, quoteBarCycle;
import preview_ansi : renderPreviewAnsi;
import previewer : BackgroundMode, TermOut;
import tui_input : beginTuiInput, TuiInput, TuiKey, TuiKind;

private enum RgbColor fallbackFg = RgbColor(0xcc, 0xcc, 0xcc);
private enum RgbColor fallbackBg = RgbColor(0x1e, 0x1e, 0x1e);

/// The scrolling viewer state: the document (markdown model or raw source), the
/// theme list, and the current scroll / theme / view-mode. Laid out once per
/// theme / width / view change into `plines`; each frame culls a viewport slice
/// and paints it.
struct PreviewTui
{
    string title;
    const(char)[] source;
    const(HighlightEvent)[] events;
    PreviewModel model;             // present ⇒ a markdown file (preview available)
    LabelSet labels;
    const(string)[] names;          // theme names, parallel to `themes`
    immutable(Theme)[] themes;
    BackgroundMode background;
    ColorDepth depth;

    private size_t themeIdx;
    private long top;               // first visible visual line
    private bool showPreview;       // preview vs raw source (Tab)
    private int width, height;      // last-measured terminal size
    private PreviewLine[] plines;   // laid out for (themeIdx, width, showPreview)
    private ResolvedTheme theme;
    private RgbColor pageFg, pageBg;
    private RgbColor[quoteBarCycle] bars;
    private SmallBuffer!(char, 16384) frame;

    /// Rebuild the laid-out lines for the current theme / width / view mode (GC;
    /// run on a theme, resize, or toggle change — never per frame).
    private void relayout() @system
    {
        theme = resolveTheme(themes[themeIdx], labels);
        pageFg = toRgb(theme.defaults.fg, fallbackFg);
        pageBg = toRgb(theme.defaults.bg, fallbackBg);
        bars = quoteBarColors(theme, pageFg, pageBg);
        const w = width < 8 ? 8 : width;
        if (showPreview && model.present)
            plines = layoutPreview(model, theme, pageFg, pageBg, w);
        else
            plines = buildRawPlines(source, events, theme, pageFg, pageBg, w);
        clampTop();
    }

    private int bodyRows() const @safe pure nothrow @nogc
        => height > 2 ? height - 2 : 1;

    private long maxTop() const @safe pure nothrow @nogc
    {
        const over = cast(long) plines.length - bodyRows();
        return over > 0 ? over : 0;
    }

    private void clampTop() @safe pure nothrow @nogc
    {
        if (top > maxTop) top = maxTop;
        if (top < 0) top = 0;
    }

    // Emit a chrome-styled (theme fg/bg) full-width line: text, erase to EOL,
    // reset. `nl` ends the row (the final status line omits it to avoid scroll).
    private void chromeLine(scope const(char)[] text, bool nl) @safe
    {
        writeStyleTransition(frame, TermStyle.init,
            TermStyle(fg: Color.fromRgb(pageFg), bg: Color.fromRgb(pageBg)), depth);
        frame.put(text);
        frame.put(cast(string) CtlSeq.eraseToEnd);
        writeStyleTransition(frame,
            TermStyle(fg: Color.fromRgb(pageFg), bg: Color.fromRgb(pageBg)),
            TermStyle.init, depth);
        if (nl)
            frame.put("\n");
    }

    // Assemble one full-screen frame into `frame`.
    private void buildFrame() @system
    {
        const rows = bodyRows();
        frame.clear();
        frame.put(CtlSeq.syncBegin);
        frame.put(CtlSeq.cursorHome);

        // Header.
        SmallBuffer!(char, 256) hdr;
        hdr.put(" ");
        hdr.put(title);
        hdr.put("  ·  ");
        hdr.put(names[themeIdx]);
        hdr.put(" (");
        writeInteger(hdr, themeIdx + 1);
        hdr.put("/");
        writeInteger(hdr, names.length);
        hdr.put(")  ·  ");
        hdr.put((showPreview && model.present) ? "preview" : "raw");
        hdr.put("  ·  ");
        writeInteger(hdr, cast(size_t)(top + 1));
        hdr.put("/");
        writeInteger(hdr, plines.length);
        chromeLine(hdr[], nl: true);

        // Body viewport.
        const first = cast(size_t) top;
        const last = first + rows > plines.length ? plines.length : first + rows;
        if (first < last)
            renderPreviewAnsi(frame, plines[first .. last], pageFg, pageBg, bars,
                depth, background);
        // Pad any rows beyond the document's end with blank chrome lines.
        foreach (_; 0 .. rows - (last - first))
            chromeLine("", nl: true);

        // Status / hint line (no trailing newline — keeps the last row put).
        chromeLine(" ↑↓ PgUp/PgDn Home/End scroll · ←→ theme · Tab raw/preview · q quit",
            nl: false);

        frame.put(CtlSeq.syncEnd);
    }

    // Apply a key; returns false to quit.
    private bool handle(TuiKey k) @system
    {
        const rows = bodyRows();
        switch (k.kind)
        {
            case TuiKind.up:       top -= 1; clampTop(); break;
            case TuiKind.down:     top += 1; clampTop(); break;
            case TuiKind.pageUp:   top -= rows; clampTop(); break;
            case TuiKind.pageDown: top += rows; clampTop(); break;
            case TuiKind.home:     top = 0; break;
            case TuiKind.end:      top = maxTop; break;
            case TuiKind.left:
                themeIdx = themeIdx == 0 ? names.length - 1 : themeIdx - 1;
                relayout();
                break;
            case TuiKind.right:
                themeIdx = themeIdx + 1 == names.length ? 0 : themeIdx + 1;
                relayout();
                break;
            case TuiKind.tab:
                if (model.present)
                {
                    showPreview = !showPreview;
                    relayout();
                }
                break;
            case TuiKind.resize:
                measureAndReflow();
                break;
            case TuiKind.character:
                if (k.ch == 'q')
                    return false;
                if (k.ch == 'j') { top += 1; clampTop(); }
                else if (k.ch == 'k') { top -= 1; clampTop(); }
                else if (k.ch == 'g') { top = 0; }
                else if (k.ch == 'G') { top = maxTop; }
                break;
            case TuiKind.escape, TuiKind.eof:
                return false;
            default:
                break;
        }
        return true;
    }

    // Re-measure the terminal; relayout if the width changed, else just reclamp.
    private void measureAndReflow() @system
    {
        const sz = terminalSize(StdStream.stdout);
        const w = sz.width > 0 ? sz.width : 80;
        const h = sz.height > 0 ? sz.height : 24;
        const widthChanged = w != width;
        width = w;
        height = h;
        if (widthChanged)
            relayout();
        else
            clampTop();
    }
}

/// Run the interactive scrolling viewer until the user quits. Enters the
/// alt-screen (hidden cursor, autowrap off), lays out the document, then loops
/// build-frame → flush → read-key. Restores the terminal on exit. `themeIdx` is
/// the starting theme; `startPreview` opens a markdown file in the decorated
/// preview (else raw source). Returns 0.
int runPreviewTui(ref PreviewTui t, size_t themeIdx, bool startPreview) @system
{
    t.themeIdx = themeIdx < t.names.length ? themeIdx : 0;
    t.showPreview = startPreview;

    auto input = beginTuiInput();
    if (!input.active)
        return 1; // not a real tty — caller should have used the ANSI emit
    scope (exit) input.finish();

    auto sink = TermOut.standard();
    sink.put(CtlSeq.enterAltScreen);
    sink.put(CtlSeq.hideCursor);
    sink.put("\x1b[?7l"); // autowrap off — full-width lines must not wrap
    scope (exit)
    {
        sink.put("\x1b[?7h");
        sink.put(CtlSeq.showCursor);
        sink.put(CtlSeq.exitAltScreen);
        sink.flush();
    }

    t.measureAndReflow(); // sets width/height and lays out
    for (;;)
    {
        t.buildFrame();
        sink.put(t.frame[]);
        sink.flush();
        if (!t.handle(input.next()))
            break;
    }
    return 0;
}
