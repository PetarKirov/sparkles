// Terminal (SGR) painter for the markdown-preview model — the cell-grid analog
// of `gui.d`'s `drawPreview`. It consumes the same raylib-free `PreviewLine[]`
// that `gui_preview.layoutPreview` produces and folds each run's neutral
// `RgbColor` + `Attr` onto SGR escapes (`writeStyleTransition`), so the terminal
// and GUI render one shared preview ("one model, two painters" — tui.md `MDP-T`).
//
// Compiled into every hue build (default `application` and `no-gui`): it needs
// no raylib and no ghostty (ansi fences are stripped to plain text upstream when
// no off-screen VT is available). The layout is done once; this paint core
// allocates nothing, so a `@nogc` writer keeps it `@nogc`.
module preview_ansi;

import sparkles.base.term_color : Color, ColorDepth, RgbColor;
import sparkles.base.term_style : TermStyle, TextAttr, UnderlineStyle, writeStyleTransition;
import sparkles.base.term_control : CtlSeq;

import ansi_model : Attr;
import gui_preview : BandKind, PreviewLine, PreviewRun, quoteBarCycle;
import ansi_model : BackgroundMode;

// Emit `n` spaces without allocating (chunks of a static blank run).
private void putSpaces(Writer)(ref Writer w, size_t n)
{
    import std.range.primitives : put;

    static immutable char[64] blanks = ' ';
    while (n)
    {
        const k = n < blanks.length ? n : blanks.length;
        put(w, blanks[0 .. k]);
        n -= k;
    }
}

// A `TermStyle` from the preview's neutral colors + `Attr` bits (`underline` is a
// first-class `TermStyle` field, not a `TextAttr` bit).
private TermStyle toStyle(RgbColor fg, bool hasBg, RgbColor bgc, ubyte attrs) @safe pure nothrow @nogc
{
    TextAttr ta;
    if (attrs & Attr.bold)          ta = ta | TextAttr.bold;
    if (attrs & Attr.italic)        ta = ta | TextAttr.italic;
    if (attrs & Attr.strikethrough) ta = ta | TextAttr.strikethrough;
    return TermStyle(
        fg: Color.fromRgb(fg),
        bg: hasBg ? Color.fromRgb(bgc) : Color.init,
        attrs: ta,
        underline: (attrs & Attr.underline) ? UnderlineStyle.single : UnderlineStyle.none,
    );
}

/**
Paint a laid-out `PreviewLine[]` (from `gui_preview.layoutPreview`) into `w` as
SGR terminal cells. Each line emits its background fill (per `bg`), `indentCols`
leading spaces, `quoteDepth` colored `│` gutter bars, the `leader`
(bullet / checkbox / heading icon), then the styled runs; `full` background mode
fills each line edge-to-edge via back-color-erase. `RgbColor` folds to the
terminal's `depth`. `bars` are the per-depth quote-bar colors
(`gui_preview.quoteBarColors`). Allocation-free — layout is done once, upstream.
*/
void renderPreviewAnsi(Writer)(ref Writer w, in PreviewLine[] lines,
    RgbColor pageFg, RgbColor pageBg, in RgbColor[quoteBarCycle] bars,
    ColorDepth depth, BackgroundMode bg,
    RgbColor selBg = RgbColor.init, long absStart = 0, long selLo = -1, long selHi = -1)
{
    import std.range.primitives : put;

    // Muted leader / decorations: the midpoint of page fg/bg (matches gui.d's
    // 2-arg `mix`, which is a private per-file helper).
    const gutterFg = RgbColor(
        cast(ubyte)((pageFg.r + pageBg.r) / 2),
        cast(ubyte)((pageFg.g + pageBg.g) / 2),
        cast(ubyte)((pageFg.b + pageBg.b) / 2));
    TermStyle cur;                        // current SGR state (terminal default)

    void setStyle(TermStyle s)
    {
        writeStyleTransition(w, cur, s, depth);
        cur = s;
    }

    void emit(scope const(char)[] text, TermStyle s)
    {
        setStyle(s);
        put(w, text);
    }

    foreach (idx, ref pl; lines)
    {
        // A selected line (its absolute index within [selLo, selHi]) paints every
        // cell — content and fill — with the uniform selection background.
        const sel = selLo >= 0 && absStart + cast(long) idx >= selLo
            && absStart + cast(long) idx <= selHi;

        // The fill color for indent / leader / trailing cells (a band's own runs
        // carry their bg). Heading bands tint full width; `full` fills with the
        // page bg; `spans` / `no-background` leave the terminal's bg showing.
        bool hasFill;
        RgbColor fillBg;
        final switch (bg)
        {
            case BackgroundMode.noBackground:
                hasFill = false;
                break;
            case BackgroundMode.spans:
                hasFill = pl.band == BandKind.heading;
                fillBg = pl.bandBg;
                break;
            case BackgroundMode.full:
                hasFill = true;
                fillBg = pl.band == BandKind.heading ? pl.bandBg : pageBg;
                break;
        }
        if (sel)
        {
            hasFill = true;
            fillBg = selBg;
        }

        if (pl.indentCols > 0)
        {
            setStyle(toStyle(pageFg, hasFill, fillBg, 0));
            putSpaces(w, pl.indentCols);
        }

        foreach (d; 0 .. pl.quoteDepth)
        {
            const barFg = pl.hasBarFg ? pl.barFg : bars[d % quoteBarCycle];
            emit("│", toStyle(barFg, hasFill, fillBg, 0));
            emit(" ", toStyle(pageFg, hasFill, fillBg, 0)); // 2-column spacing
        }

        if (pl.leader.length)
            emit(pl.leader, toStyle(pl.hasLeaderFg ? pl.leaderFg : gutterFg, hasFill, fillBg, 0));

        foreach (ref r; pl.runs)
        {
            bool rHasBg;
            RgbColor rBg;
            if (sel) { rHasBg = true; rBg = selBg; }
            else if (bg != BackgroundMode.noBackground)
            {
                if (r.hasBg) { rHasBg = true; rBg = r.bg; }
                else if (hasFill) { rHasBg = true; rBg = fillBg; }
            }
            emit(r.text, toStyle(r.fg, rHasBg, rBg, r.attrs));
        }

        // Fill the rest of the line with the fill color (back-color-erase).
        if (hasFill)
        {
            setStyle(TermStyle(bg: Color.fromRgb(fillBg)));
            put(w, cast(string) CtlSeq.eraseToEnd);
        }

        setStyle(TermStyle.init); // reset, end the line
        put(w, "\n");
    }
}

@("preview_ansi.render.runsAndFill")
@safe
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import std.algorithm.searching : canFind;

    PreviewLine[] lines = [
        PreviewLine(runs: [PreviewRun("hello", RgbColor(255, 0, 0), RgbColor.init, false, Attr.bold)]),
    ];
    RgbColor[quoteBarCycle] bars;
    SmallBuffer!char buf;
    renderPreviewAnsi(buf, lines, RgbColor(200, 200, 200), RgbColor(20, 20, 20),
        bars, ColorDepth.trueColor, BackgroundMode.full);

    const s = buf[];
    assert(s.canFind("hello"), s);
    // writeStyleTransition folds bold + fg + bg into one SGR sequence.
    assert(s.canFind("1;38;2;255;0;0"), s); // bold + truecolor fg
    assert(s.canFind("48;2;20;20;20"), s);  // truecolor bg (full-mode fill)
    assert(s.canFind("\x1b[0K"), s);        // full-mode edge fill
}

@("preview_ansi.render.quoteBarsAndLeader")
@safe
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import std.algorithm.searching : canFind;

    PreviewLine[] lines = [
        PreviewLine(quoteDepth: 2, leader: "● ", runs: [
            PreviewRun("item", RgbColor(180, 180, 180), RgbColor.init, false, 0)]),
    ];
    RgbColor[quoteBarCycle] bars = [
        RgbColor(1, 1, 1), RgbColor(2, 2, 2), RgbColor(3, 3, 3), RgbColor(4, 4, 4)];
    SmallBuffer!char buf;
    renderPreviewAnsi(buf, lines, RgbColor(200, 200, 200), RgbColor(20, 20, 20),
        bars, ColorDepth.trueColor, BackgroundMode.spans);

    const s = buf[];
    assert(s.canFind("│"), s);       // quote bars
    assert(s.canFind("● "), s);      // leader
    assert(s.canFind("item"), s);
    assert(!s.canFind("\x1b[0K"), s); // no edge fill in `spans` mode
}
