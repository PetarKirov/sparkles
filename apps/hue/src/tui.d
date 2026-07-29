// hue's full-screen terminal viewer — the interactive TUI port of the GUI, built
// on `sparkles:tui`. It reuses the GUI's raylib-free layout (`gui_preview`
// `layoutPreview` / `buildRawPlines` → the wrapped `PreviewLine[]`) and paints it
// into a `sparkles.tui.Grid`; the library's `Terminal` cell-diffs each frame and
// writes only the changed cells (so scrolling emits a minimal update — no full
// repaint, no flicker), and `PosixEvents` decodes input.
//
// Covers scrolling, a raw/preview toggle, live theme cycling, a cell scrollbar,
// mouse (wheel + scrollbar + drag-selection → OSC 52), incremental search, and
// reflow on resize. Posix-only; Windows degrades to the non-interactive emit.
module tui;

version (Posix):

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.writers : writeInteger;

import sparkles.syntax : ColorDepth, HighlightEvent, LabelSet, ResolvedTheme,
    resolveTheme, RgbColor, Theme, toRgb;

import sparkles.tui : Cell, CellStyle, Color, Grid, PosixEvents, Terminal,
    TerminalOptions, TextAttr, UnderlineStyle;
import sparkles.tui.input : Event, EventKind, Key, MouseAction, MouseButton;

import ansi_model : Attr;
import gui_preview : BandKind, buildRawPlines, layoutPreview, PreviewLine,
    PreviewModel, quoteBarColors, quoteBarCycle;
import gui_text : columnWidth;
import previewer : BackgroundMode;

private enum RgbColor fallbackFg = RgbColor(0xcc, 0xcc, 0xcc);
private enum RgbColor fallbackBg = RgbColor(0x1e, 0x1e, 0x1e);

// Linear blend a→b by t∈[0,1] (matches gui.d's 3-arg `mix`, a private helper).
private RgbColor mix(RgbColor a, RgbColor b, double t) @safe pure nothrow @nogc
{
    ubyte c(ubyte x, ubyte y) => cast(ubyte)(x + cast(int)((cast(int) y - x) * t));
    return RgbColor(c(a.r, b.r), c(a.g, b.g), c(a.b, b.b));
}

// A cell style from the preview's neutral RgbColor + `Attr` bits (underline is a
// first-class field on the compact style, not a `TextAttr` bit).
private CellStyle cellStyle(RgbColor fg, bool hasBg, RgbColor bg, ubyte attrs)
    @safe pure nothrow @nogc
{
    TextAttr ta;
    if (attrs & Attr.bold)          ta = ta | TextAttr.bold;
    if (attrs & Attr.italic)        ta = ta | TextAttr.italic;
    if (attrs & Attr.strikethrough) ta = ta | TextAttr.strikethrough;
    return CellStyle(
        fg: Color.fromRgb(fg),
        bg: hasBg ? Color.fromRgb(bg) : Color.init,
        attrs: ta,
        underline: (attrs & Attr.underline) ? UnderlineStyle.single : UnderlineStyle.none);
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
/// and paints it into a cell grid.
struct PreviewTui
{
    string title;
    const(char)[] source;
    const(HighlightEvent)[] events;
    PreviewModel model;             // present ⇒ a markdown file (preview available)
    LabelSet labels;
    const(string)[] names;          // theme names, parallel to `themes`
    immutable(Theme)[] themes;
    BackgroundMode background;      // (kept for the caller; the viewer paints full-bg)
    ColorDepth depth;               // (unused: the cell renderer emits truecolor)

    private size_t themeIdx;
    private long top;               // first visible visual line
    private bool showPreview;       // preview vs raw source (Tab)
    private int width, height;      // last-measured terminal size
    private PreviewLine[] plines;   // laid out for (themeIdx, width, showPreview)
    private ResolvedTheme theme;
    private RgbColor pageFg, pageBg, gutterFg;
    private RgbColor[quoteBarCycle] bars;
    private RgbColor sbTrack, sbThumb; // scrollbar track / thumb (theme-tinted)

    // Incremental search (`/`): `searching` is input mode; `qbuf[0 .. qlen]` is
    // the query, reused by `n`/`N`. `scratch` concatenates a line's run text for
    // substring matching.
    private bool searching;
    private char[256] qbuf;
    private size_t qlen;
    private SmallBuffer!(char, 4096) scratch;

    // Selection (mouse drag) → OSC 52 copy. `selAnchor`/`selCursor` are visual
    // line indices (-1 ⇒ no selection); `selBg` tints the selected lines. `clip`
    // holds a pending OSC 52 sequence that the loop flushes after a copy.
    private long selAnchor = -1, selCursor = -1;
    private RgbColor selBg;
    private SmallBuffer!char clip;
    private bool clipReady;

    // Copy-button feedback: the fence/table just copied shows a ✔ until the next
    // event (the loop is event-driven, so there is no timed flash). -1 ⇒ none.
    private int copiedFence = -1, copiedTable = -1;

    private const(char)[] query() const return @safe pure nothrow @nogc => qbuf[0 .. qlen];

    /// Rebuild the laid-out lines for the current theme / width / view mode (GC;
    /// run on a theme, resize, or toggle change — never per frame).
    private void relayout() @system
    {
        theme = resolveTheme(themes[themeIdx], labels);
        pageFg = toRgb(theme.defaults.fg, fallbackFg);
        pageBg = toRgb(theme.defaults.bg, fallbackBg);
        gutterFg = mix(pageFg, pageBg, 0.5); // muted leader / decorations
        bars = quoteBarColors(theme, pageFg, pageBg);
        // Scrollbar chrome + selection: tint toward the theme link color (gui.d).
        const linkC = toRgb(theme[theme.labels.resolve("markup.link")].fg, pageFg);
        sbTrack = mix(pageBg, linkC, 0.22);
        sbThumb = mix(pageBg, linkC, 0.5);
        selBg = mix(pageBg, linkC, 0.4);
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

    private void clampSel() @safe pure nothrow @nogc
    {
        const last = cast(long) plines.length - 1;
        if (selAnchor > last) selAnchor = last;
        if (selCursor > last) selCursor = last;
        if (selAnchor < 0) selAnchor = 0;
        if (selCursor < 0) selCursor = 0;
    }

    // Copy the selected visual lines' **original source** (SEL parity): the min
    // src offset .. max src end over the selected lines' content runs (decoration
    // runs have no src offset and are excluded), written to the system clipboard
    // via OSC 52. Clears the selection.
    private void copySelection() @system
    {
        if (selAnchor < 0 || plines.length == 0)
            return;
        const lo = selAnchor < selCursor ? selAnchor : selCursor;
        const hi = selAnchor < selCursor ? selCursor : selAnchor;
        size_t a = size_t.max, b;
        bool any;
        foreach (i; lo .. hi + 1)
        {
            if (i < 0 || i >= cast(long) plines.length)
                continue;
            foreach (ref r; plines[cast(size_t) i].runs)
            {
                if (r.srcStart == size_t.max)
                    continue; // a synthetic decoration run (gutter / bullet / box)
                any = true;
                if (r.srcStart < a)
                    a = r.srcStart;
                const e = r.srcStart + r.text.length;
                if (e > b)
                    b = e;
            }
        }
        if (!any || a >= b || b > source.length)
        {
            selAnchor = selCursor = -1;
            return;
        }
        writeClipboard(source[a .. b]);
        selAnchor = selCursor = -1;
    }

    // Queue `text` for the system clipboard via OSC 52 (`ESC ] 52 ; c ; <b64> BEL`),
    // the only portable in-band terminal clipboard; the loop flushes `clip` after.
    private void writeClipboard(scope const(char)[] text) @system
    {
        import std.base64 : Base64;

        clip.clear();
        clip.put("\x1b]52;c;");
        clip.put(Base64.encode(cast(const(ubyte)[]) text));
        clip.put("\x07");
        clipReady = true;
    }

    // Column of a line's copy button (code header / table top border) — the middle
    // of the border's 3-space cutout, `lineCols-3` from the content origin. -1 when
    // the line has no button.
    private int copyButtonCol(in PreviewLine pl) @safe
    {
        if (pl.copyFence < 0 && pl.copyTable < 0)
            return -1;
        int start = pl.quoteDepth * 2 + pl.indentCols + cast(int) columnWidth(pl.leader);
        int cols;
        foreach (ref r; pl.runs)
            cols += cast(int) columnWidth(r.text);
        return start + cols - 3;
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

    // The nearest matching line from `from` in the given direction (wrapping);
    // scrolls it to the top when found.
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

    // ── Painting into the cell grid ──────────────────────────────────────────

    /// Paint the whole frame into `g` (immediate mode). The library diffs it
    /// against the last frame, so only changed cells reach the wire.
    void paint(ref Grid g) @system
    {
        // Fill the screen with the theme background (the full-screen look).
        g.clearTo(cellStyle(pageFg, true, pageBg, 0));
        paintHeader(g);

        const rows = bodyRows();
        const first = cast(size_t) top;
        const last = first + rows > plines.length ? plines.length : first + rows;
        long sLo = -1, sHi = -1;
        if (selAnchor >= 0)
        {
            sLo = selAnchor < selCursor ? selAnchor : selCursor;
            sHi = selAnchor < selCursor ? selCursor : selAnchor;
        }
        ushort y = 1;
        foreach (i; first .. last)
        {
            const sel = sLo >= 0 && cast(long) i >= sLo && cast(long) i <= sHi;
            paintLine(g, y, plines[i], sel);
            ++y;
        }
        paintScrollbar(g);
        paintStatus(g);
    }

    private void paintHeader(ref Grid g) @system
    {
        SmallBuffer!(char, 256) h;
        h.put(" ");
        h.put(title);
        h.put("  ·  ");
        h.put(names[themeIdx]);
        h.put(" (");
        writeInteger(h, themeIdx + 1);
        h.put("/");
        writeInteger(h, names.length);
        h.put(")  ·  ");
        h.put((showPreview && model.present) ? "preview" : "raw");
        h.put("  ·  ");
        writeInteger(h, cast(size_t)(top + 1));
        h.put("/");
        writeInteger(h, plines.length);
        g.putText(0, 0, h[], cellStyle(pageFg, true, pageBg, 0)); // Grid clips at the edge
    }

    private void paintStatus(ref Grid g) @system
    {
        const y = cast(ushort)(height > 0 ? height - 1 : 0);
        if (searching)
        {
            SmallBuffer!(char, 300) s;
            s.put(" /");
            s.put(query);
            s.put("▏");
            g.putText(0, y, s[], cellStyle(pageFg, true, pageBg, 0));
        }
        else
            g.putText(0, y,
                " scroll ↑↓/PgUp/PgDn · ←→ theme · Tab raw/preview · / search · drag+y copy · q quit",
                cellStyle(pageFg, true, pageBg, 0));
    }

    // Paint one laid-out preview line into grid row `y`: the row-fill background
    // (selection / heading band / page), then quote bars, the leader, and runs.
    private void paintLine(ref Grid g, ushort y, in PreviewLine pl, bool sel) @system
    {
        const fillBg = sel ? selBg : (pl.band == BandKind.heading ? pl.bandBg : pageBg);
        g.fill(0, y, g.cols, cellStyle(pageFg, true, fillBg, 0));

        ushort x = pl.indentCols > 0 ? cast(ushort) pl.indentCols : 0;
        foreach (d; 0 .. pl.quoteDepth)
        {
            const barFg = pl.hasBarFg ? pl.barFg : bars[d % quoteBarCycle];
            if (x < g.cols)
                x = g.putText(x, y, "│", cellStyle(barFg, true, fillBg, 0));
            if (x < g.cols)
                ++x; // the 2-column bar spacing (already fillBg from the row fill)
        }
        if (pl.leader.length && x < g.cols)
            x = g.putText(x, y, pl.leader,
                cellStyle(pl.hasLeaderFg ? pl.leaderFg : gutterFg, true, fillBg, 0));
        foreach (ref r; pl.runs)
        {
            if (x >= g.cols)
                break;
            const rbg = sel ? selBg : (r.hasBg ? r.bg : fillBg);
            x = g.putText(x, y, r.text, cellStyle(r.fg, true, rbg, r.attrs));
        }

        // Copy button in the border cutout (code header / table top border),
        // preserving the cutout cell's background.
        const bcol = copyButtonCol(pl);
        if (bcol >= 0 && bcol < g.cols)
        {
            const copied = (pl.copyFence >= 0 && pl.copyFence == copiedFence)
                || (pl.copyTable >= 0 && pl.copyTable == copiedTable);
            auto st = cellStyle(copied ? bars[2] : gutterFg, false, RgbColor.init, 0);
            st.bg = g[cast(ushort) bcol, y].style.bg;
            g.putText(cast(ushort) bcol, y, copied ? "\U0000F00C" : "\U0000F0C5", st); //  /
        }
    }

    // A cell scrollbar in the last column across the body rows, sized/positioned
    // to the visible fraction. Only shown when the document overflows the viewport.
    private void paintScrollbar(ref Grid g) @system
    {
        const rows = bodyRows();
        if (cast(long) plines.length <= rows || g.cols < 2)
            return;
        int thumb = cast(int)(cast(long) rows * rows / cast(long) plines.length);
        if (thumb < 1) thumb = 1;
        if (thumb > rows) thumb = rows;
        const denom = maxTop();
        const thumbTop = denom > 0 ? cast(int)(top * (rows - thumb) / denom) : 0;

        const col = cast(ushort)(g.cols - 1);
        foreach (r; 0 .. rows)
        {
            const inThumb = r >= thumbTop && r < thumbTop + thumb;
            g.putText(col, cast(ushort)(r + 1), inThumb ? "█" : "░",
                cellStyle(inThumb ? sbThumb : sbTrack, true, pageBg, 0));
        }
    }

    // ── Input ────────────────────────────────────────────────────────────────

    // Copy a copy-button's target to the clipboard (OSC 52): a code fence copies
    // its raw body, a table its raw markdown source. Sets the ✔ marker.
    private void copyButton(in PreviewLine pl) @system
    {
        if (pl.copyFence >= 0 && pl.copyFence < cast(int) model.fences.length)
        {
            writeClipboard(model.fences[pl.copyFence].body);
            copiedFence = pl.copyFence;
            copiedTable = -1;
        }
        else if (pl.copyTable >= 0 && pl.selSrcStart != size_t.max
            && pl.selSrcEnd <= source.length)
        {
            writeClipboard(source[pl.selSrcStart .. pl.selSrcEnd]);
            copiedTable = pl.copyTable;
            copiedFence = -1;
        }
    }

    // Apply an event; returns false to quit.
    private bool handle(in Event e) @system
    {
        copiedFence = copiedTable = -1; // the ✔ flash lasts until the next event
        if (searching)
            return handleSearch(e);
        if (e.kind == EventKind.mouse)
            return handleMouse(e);
        if (e.kind == EventKind.eof)
            return false;
        if (e.kind != EventKind.key)
            return true;

        const rows = bodyRows();
        switch (e.key)
        {
            case Key.up:       top -= 1; clampTop(); break;
            case Key.down:     top += 1; clampTop(); break;
            case Key.pageUp:   top -= rows; clampTop(); break;
            case Key.pageDown: top += rows; clampTop(); break;
            case Key.home:     top = 0; break;
            case Key.end:      top = maxTop; break;
            case Key.left:
                themeIdx = themeIdx == 0 ? names.length - 1 : themeIdx - 1;
                relayout();
                break;
            case Key.right:
                themeIdx = themeIdx + 1 == names.length ? 0 : themeIdx + 1;
                relayout();
                break;
            case Key.tab:
                if (model.present)
                {
                    showPreview = !showPreview;
                    relayout();
                }
                break;
            case Key.escape:
                return false;
            case Key.char_:
                switch (e.ch)
                {
                    case 'q': return false;
                    case 'j': top += 1; clampTop(); break;
                    case 'k': top -= 1; clampTop(); break;
                    case 'g': top = 0; break;
                    case 'G': top = maxTop; break;
                    case '/': searching = true; qlen = 0; break;
                    case 'n': jumpMatch(top + 1, true); break;
                    case 'N': jumpMatch(top - 1, false); break;
                    case 'y': copySelection(); break;
                    default: break;
                }
                break;
            default: break;
        }
        return true;
    }

    private bool handleMouse(in Event e) @system
    {
        const rows = bodyRows();
        if (e.action == MouseAction.wheelUp)        { top -= 3; clampTop(); }
        else if (e.action == MouseAction.wheelDown) { top += 3; clampTop(); }
        else if (e.button == MouseButton.left
            && (e.action == MouseAction.press || e.action == MouseAction.drag)
            && e.mouse.row >= 2 && e.mouse.row <= 1 + rows)
        {
            if (e.mouse.col == width) // the scrollbar column (last, 1-based == width)
            {
                const span = rows > 1 ? rows - 1 : 1;
                top = cast(long)(e.mouse.row - 2) * maxTop / span;
                clampTop();
            }
            else
            {
                // Body — a click on a copy button copies (and doesn't select);
                // otherwise start (press) or extend (drag) a line selection.
                const line = top + (e.mouse.row - 2);
                if (e.action == MouseAction.press && line >= 0
                    && line < cast(long) plines.length)
                {
                    const pl = plines[cast(size_t) line];
                    const bcol = copyButtonCol(pl);
                    if (bcol >= 0 && cast(int)(e.mouse.col - 1) == bcol)
                    {
                        copyButton(pl);
                        return true;
                    }
                }
                if (e.action == MouseAction.press)
                    selAnchor = line;
                selCursor = line;
                clampSel();
            }
        }
        return true;
    }

    // Key handling while typing a search query (`/…`): printable keys extend it,
    // backspace trims, Enter commits, Esc cancels; the view live-jumps to the
    // first match as the query changes.
    private bool handleSearch(in Event e) @system
    {
        if (e.kind != EventKind.key)
            return true;
        switch (e.key)
        {
            case Key.char_:
                if (qlen < qbuf.length)
                    qbuf[qlen++] = cast(char) e.ch;
                jumpMatch(top, true);
                break;
            case Key.backspace:
                if (qlen)
                    --qlen;
                jumpMatch(top, true);
                break;
            case Key.enter:
                searching = false;
                jumpMatch(top + 1, true); // move off the current match
                break;
            case Key.escape:
                searching = false;
                qlen = 0;
                break;
            default: break;
        }
        return true;
    }
}

/// Run the interactive scrolling viewer until the user quits. Uses `sparkles:tui`
/// for the terminal lifecycle + cell-diffed frame flush and for input decoding.
/// `themeIdx` is the starting theme; `startPreview` opens a markdown file in the
/// decorated preview (else raw source). Returns 0 (1 if stdin isn't a tty).
int runPreviewTui(ref PreviewTui t, size_t themeIdx, bool startPreview) @system
{
    t.themeIdx = themeIdx < t.names.length ? themeIdx : 0;
    t.showPreview = startPreview;

    auto term = Terminal.open();
    if (!term.active)
        return 1; // not a real tty — the caller should have used the ANSI emit
    scope (exit) term.close();

    auto events = PosixEvents.start();

    Grid g;
    for (;;)
    {
        const sz = term.size();
        if (sz.width != t.width) // width changed (or first frame) → reflow layout
        {
            t.width = sz.width;
            t.height = sz.height;
            t.relayout();
        }
        else
        {
            t.height = sz.height;
            t.clampTop();
        }

        g.resize(sz.width, sz.height);
        t.paint(g);
        term.draw(g); // cell-diff: only changed cells reach the terminal

        if (t.clipReady)
        {
            term.writeRaw(t.clip[]); // OSC 52 clipboard write (out of band)
            t.clipReady = false;
        }

        const ev = events.next();
        if (ev.kind == EventKind.eof)
            break;
        if (ev.kind == EventKind.resize)
            continue; // next iteration re-measures + reflows
        if (!t.handle(ev))
            break;
    }
    return 0;
}

@("tui.paint.rawGridContent")
@system
unittest
{
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet;
    import std.algorithm.searching : canFind;

    static immutable src = "hello\nworld\n";
    static HighlightEvent[1] ev = [HighlightEvent.sourceSpan(0, src.length)];
    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];

    PreviewTui t;
    t.title = "doc.md";
    t.source = src;
    t.events = ev[];
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 60;
    t.height = 6;
    t.relayout(); // raw view (no markdown model present)

    Grid g;
    g.resize(60, 6);
    t.paint(g);

    string row(ushort y)
    {
        string s;
        foreach (x; 0 .. g.cols)
            s ~= g[cast(ushort) x, y].grapheme;
        return s;
    }

    assert(row(0).canFind("doc.md"), row(0)); // header: title
    assert(row(0).canFind("dark"), row(0));   // header: theme name
    assert(row(0).canFind("raw"), row(0));    // header: view mode
    assert(row(1).canFind("hello"), row(1));  // first source line, painted into the grid
    assert(row(2).canFind("world"), row(2));  // second source line
}

@("tui.paint.copyButton")
@system
unittest
{
    import sparkles.syntax : builtinDark, ColAlign, MdBlock, MdBlockKind, MdDoc,
        MdInline, MdInlineKind, Span, LabelSet;
    import std.algorithm.searching : canFind;

    // A hand-built 2×2 table model (no grammar needed) rendered in preview mode.
    static immutable src = "a b c d";
    static MdBlock cell(size_t a, size_t b)
        => MdBlock(kind: MdBlockKind.tableCell,
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(a, b))]);
    auto tbl = MdBlock(kind: MdBlockKind.table, span: Span(0, src.length),
        aligns: [ColAlign.left, ColAlign.left], children: [
            MdBlock(kind: MdBlockKind.tableRow, children: [cell(0, 1), cell(2, 3)]),
            MdBlock(kind: MdBlockKind.tableRow, children: [cell(4, 5), cell(6, 7)]),
        ]);

    static immutable(Theme)[1] themes = [builtinDark];
    static immutable string[1] names = ["dark"];
    PreviewTui t;
    t.title = "t.md";
    t.source = src;
    t.model = PreviewModel(present: true, doc: MdDoc(
        MdBlock(kind: MdBlockKind.document, children: [tbl]), src));
    t.labels = LabelSet.standard();
    t.names = names[];
    t.themes = themes[];
    t.width = 40;
    t.height = 10;
    t.showPreview = true;
    t.relayout();

    Grid g;
    g.resize(40, 10);
    t.paint(g);

    // The whole-table copy button () is painted in the top border's cutout.
    bool found;
    foreach (y; 0 .. g.rows)
        foreach (x; 0 .. g.cols)
            if (g[cast(ushort) x, cast(ushort) y].grapheme == "\U0000F0C5")
                found = true;
    assert(found, "table copy button not painted in the TUI");
}
