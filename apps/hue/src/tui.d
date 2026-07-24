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

// Linear blend a→b by t∈[0,1] (matches gui.d's 3-arg `mix`, a private helper).
private RgbColor mix(RgbColor a, RgbColor b, double t) @safe pure nothrow @nogc
{
    ubyte c(ubyte x, ubyte y) => cast(ubyte)(x + cast(int)((cast(int) y - x) * t));
    return RgbColor(c(a.r, b.r), c(a.g, b.g), c(a.b, b.b));
}

private char lowerAscii(char c) @safe pure nothrow @nogc
    => (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;

// Case-insensitive substring test (ASCII fold; allocation-free).
private bool containsIC(scope const(char)[] hay, scope const(char)[] needle) @safe pure nothrow @nogc
{
    if (needle.length == 0 || needle.length > hay.length)
        return needle.length == 0;
    foreach (i; 0 .. hay.length - needle.length + 1)
    {
        size_t j;
        while (j < needle.length && lowerAscii(hay[i + j]) == lowerAscii(needle[j]))
            ++j;
        if (j == needle.length)
            return true;
    }
    return false;
}

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
    private RgbColor sbTrack, sbThumb; // scrollbar track / thumb (theme-tinted)
    private SmallBuffer!(char, 16384) frame;

    // Incremental search (`/`): `searching` is input mode; `qbuf[0 .. qlen]` is
    // the query, reused by `n`/`N`. `scratch` concatenates a line's run text for
    // substring matching.
    private bool searching;
    private char[256] qbuf;
    private size_t qlen;
    private SmallBuffer!(char, 4096) scratch;

    private const(char)[] query() const return @safe pure nothrow @nogc => qbuf[0 .. qlen];

    /// Rebuild the laid-out lines for the current theme / width / view mode (GC;
    /// run on a theme, resize, or toggle change — never per frame).
    private void relayout() @system
    {
        theme = resolveTheme(themes[themeIdx], labels);
        pageFg = toRgb(theme.defaults.fg, fallbackFg);
        pageBg = toRgb(theme.defaults.bg, fallbackBg);
        bars = quoteBarColors(theme, pageFg, pageBg);
        // Scrollbar chrome: tint toward the theme link color (matches gui.d).
        const linkC = toRgb(theme[theme.labels.resolve("markup.link")].fg, pageFg);
        sbTrack = mix(pageBg, linkC, 0.22);
        sbThumb = mix(pageBg, linkC, 0.5);
        // Lay out to one column narrower — the last column holds the scrollbar.
        const w = width < 9 ? 8 : width - 1;
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

    // Does visual line `i` contain the query (case-insensitive, across runs)?
    private bool lineMatches(size_t i) @safe
    {
        if (qlen == 0)
            return false;
        scratch.clear();
        foreach (ref r; plines[i].runs)
            scratch.put(r.text);
        return containsIC(scratch[], query);
    }

    // The nearest matching line from `from` in the given direction (wrapping), or
    // -1 if none. Scrolls that line to the top when found.
    private void jumpMatch(long from, bool forward) @safe
    {
        const n = cast(long) plines.length;
        if (n == 0 || qlen == 0)
            return;
        foreach (step; 0 .. n)
        {
            const i = forward ? (from + step) % n : ((from - step) % n + n) % n;
            if (lineMatches(cast(size_t) i))
            {
                top = i;
                clampTop();
                return;
            }
        }
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
        if (searching)
        {
            SmallBuffer!(char, 300) st;
            st.put(" /");
            st.put(query);
            st.put("▏");
            chromeLine(st[], nl: false);
        }
        else
            chromeLine(" ↑↓/PgUp/PgDn/Home/End scroll · ←→ theme · Tab raw/preview · / search · n next · q quit",
                nl: false);

        drawScrollbar();
        frame.put(CtlSeq.syncEnd);
    }

    // Overlay a cell scrollbar in the last column across the body rows (screen
    // rows 2 .. 1+bodyRows). Absolute-positioned, so it runs after the sequential
    // body/status writes. Only shown when the document overflows the viewport.
    private void drawScrollbar() @system
    {
        const rows = bodyRows();
        if (cast(long) plines.length <= rows || width < 2)
            return;
        int thumb = cast(int)(cast(long) rows * rows / cast(long) plines.length);
        if (thumb < 1) thumb = 1;
        if (thumb > rows) thumb = rows;
        const denom = maxTop();
        const thumbTop = denom > 0 ? cast(int)(top * (rows - thumb) / denom) : 0;

        foreach (r; 0 .. rows)
        {
            frame.put("\x1b[");
            writeInteger(frame, r + 2); // body starts at screen row 2
            frame.put(";");
            writeInteger(frame, width);
            frame.put("H");
            const inThumb = r >= thumbTop && r < thumbTop + thumb;
            const col = inThumb ? sbThumb : sbTrack;
            const st = TermStyle(fg: Color.fromRgb(col), bg: Color.fromRgb(pageBg));
            writeStyleTransition(frame, TermStyle.init, st, depth);
            frame.put(inThumb ? "█" : "░");
            writeStyleTransition(frame, st, TermStyle.init, depth);
        }
    }

    // Apply a key; returns false to quit.
    private bool handle(TuiKey k) @system
    {
        const rows = bodyRows();
        if (searching)
            return handleSearch(k);
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
            case TuiKind.mouse:
                if (k.mb == 64)        { top -= 3; clampTop(); }   // wheel up
                else if (k.mb == 65)   { top += 3; clampTop(); }   // wheel down
                else if ((k.mb & 0b1000011) == 0 && k.mdown // left press / drag
                    && k.mx == width && k.my >= 2 && k.my <= 1 + rows)
                {
                    // Clicked / dragged on the scrollbar column — jump there.
                    const r = k.my - 2;                            // 0-based body row
                    const span = rows > 1 ? rows - 1 : 1;
                    top = cast(long) r * maxTop / span;
                    clampTop();
                }
                break;
            case TuiKind.resize:
                measureAndReflow();
                break;
            case TuiKind.character:
                switch (k.ch)
                {
                    case 'q': return false;
                    case 'j': top += 1; clampTop(); break;
                    case 'k': top -= 1; clampTop(); break;
                    case 'g': top = 0; break;
                    case 'G': top = maxTop; break;
                    case '/': searching = true; qlen = 0; break; // start a search
                    case 'n': jumpMatch(top + 1, true); break;   // next match
                    case 'N': jumpMatch(top - 1, false); break;  // previous match
                    default: break;
                }
                break;
            case TuiKind.escape, TuiKind.eof:
                return false;
            default:
                break;
        }
        return true;
    }

    // Key handling while typing a search query (`/…`): printable keys extend it,
    // backspace trims, Enter commits, Esc cancels. The view live-jumps to the
    // first match as the query changes.
    private bool handleSearch(TuiKey k) @system
    {
        switch (k.kind)
        {
            case TuiKind.character:
                if (qlen < qbuf.length)
                    qbuf[qlen++] = k.ch;
                jumpMatch(top, true);
                break;
            case TuiKind.backspace:
                if (qlen)
                    --qlen;
                jumpMatch(top, true);
                break;
            case TuiKind.enter:
                searching = false;
                jumpMatch(top + 1, true); // move off the current match
                break;
            case TuiKind.escape, TuiKind.eof:
                searching = false;
                qlen = 0;
                break;
            case TuiKind.resize:
                measureAndReflow();
                break;
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
    sink.put("\x1b[?7l");             // autowrap off — full-width lines must not wrap
    sink.put("\x1b[?1000;1002;1006h"); // SGR mouse: click + drag + wheel
    scope (exit)
    {
        sink.put("\x1b[?1000;1002;1006l"); // must be restored so the terminal isn't left in mouse mode
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
