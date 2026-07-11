/**
The ANSI rendering backend: folds a highlight-event stream into SGR-styled
terminal output.

Renders through $(REF byStyledSpan, sparkles,syntax,event) (maximal
innermost-wins runs), emitting the $(B minimal SGR transition) between
adjacent runs ($(LREF writeStyleTransition)) at the requested
$(REF ColorDepth, sparkles,syntax,color) tier — 24-bit, 256-color, or
classic-16, with palette colors kept palette-native so the user's terminal
scheme is respected (the bat discipline).

$(B Per-line validity:) any active style is reset before every `'\n'` and
lazily re-established after it, so each output line carries its own styling
and survives being sliced, paged, or reflowed line-wise. The invariant is
verified in tests by re-scanning the output with
`sparkles.base.text.ansi.SgrState`.

Totality: the renderer never fails on any event stream; `ColorDepth.none`
degrades to verbatim source passthrough.
*/
module sparkles.syntax.render.ansi;

import std.range.primitives : put;

import sparkles.base.text.writers : writeInteger;
import sparkles.base.text.ansi : writeSgrReset;
import sparkles.base.term_style : Style;

import sparkles.syntax.color : Color, ColorDepth, RgbColor, ansi16FromRgb,
    ansi256FromRgb, xterm256ToRgb;
import sparkles.syntax.event : byStyledSpan, isHighlightEventRange;
import sparkles.syntax.theme : FontStyle, ResolvedTheme, StyleSpec, hasFont;

/// Options for $(LREF renderAnsi).
struct AnsiOptions
{
    /// Color tier to emit. `none` = verbatim passthrough.
    ColorDepth depth = ColorDepth.ansi256;

    /// Emit per-run theme backgrounds. Off by default: respect the
    /// terminal's own background.
    bool emitBackground = false;

    /// Emit italics. Off by default (bat's defensive gate — some terminals
    /// render italics poorly); italic font flags are dropped when off.
    bool italics = false;
}

/**
Folds `events` over `source`, writing SGR-styled text to `w`.

`w` is any `char` output range. Attributes infer: with a `@nogc` writer and
event range the whole render path is `@safe pure nothrow @nogc`.
*/
ref Writer renderAnsi(Writer, Events)(
    scope const(char)[] source,
    Events events,
    in ResolvedTheme theme,
    return ref Writer w,
    in AnsiOptions options = AnsiOptions(),
)
if (isHighlightEventRange!Events)
{
    import std.algorithm.comparison : min;
    import std.algorithm.searching : countUntil;
    import std.utf : byCodeUnit;

    if (options.depth == ColorDepth.none)
    {
        put(w, source);
        return w;
    }

    StyleSpec current;

    void transitionTo(in StyleSpec target)
    {
        if (current != target)
        {
            writeStyleTransition(w, current, target, options.depth);
            current = target;
        }
    }

    foreach (span; byStyledSpan(events))
    {
        auto spec = theme[span.label];
        if (!options.italics)
            spec.font = cast(FontStyle)(spec.font & ~FontStyle.italic);
        if (!options.emitBackground)
            spec.bg = Color.init;

        // Defensive clamp: a misbehaving producer must not crash a renderer.
        const lo = min(span.start, source.length);
        const hi = min(span.end, source.length);
        const(char)[] text = lo < hi ? source[lo .. hi] : null;

        while (text.length)
        {
            const nlPos = text.byCodeUnit.countUntil('\n');
            if (nlPos < 0)
            {
                transitionTo(spec);
                put(w, text);
                break;
            }

            const nl = cast(size_t) nlPos;
            if (nl > 0)
            {
                transitionTo(spec);
                put(w, text[0 .. nl]);
            }
            // reset before the newline; re-open lazily at the next text
            transitionTo(StyleSpec.init);
            put(w, '\n');
            text = text[nl + 1 .. $];
        }
    }

    transitionTo(StyleSpec.init);
    return w;
}

/**
Emits the minimal SGR sequence transitioning the terminal from style `from`
to style `to` at `depth`; nothing when they are equal, a single `ESC[0m`
when `to` is empty.

Font bits are diffed per flag (off-codes `22`/`23`/`24`/`29` for cleared
bits, on-codes for set bits — `22` clears both bold and dim, so a surviving
one is re-issued); colors are emitted only when changed, an unset/default
target as `39`/`49`.
*/
void writeStyleTransition(Writer)(ref Writer w, in StyleSpec from, in StyleSpec to, ColorDepth depth)
{
    if (from == to)
        return;
    if (to.empty)
    {
        if (!from.empty)
            writeSgrReset(w);
        return;
    }

    put(w, "\x1b[");
    bool first = true;

    // Emit one `;`-separated SGR parameter. Codes are sourced from
    // `base.term_style.Style` ([on, off] pairs) so the numbers have one home.
    void pieceCode(uint code)
    {
        if (!first)
            put(w, ';');
        first = false;
        writeInteger(w, code);
    }

    // bold/dim share the off-code 22 (Style.bold[1] == Style.dim[1]): if either
    // is cleared, clear both and re-issue the survivor.
    const fromBD = from.font & (FontStyle.bold | FontStyle.dim);
    const toBD = to.font & (FontStyle.bold | FontStyle.dim);
    if (fromBD != toBD)
    {
        if (fromBD & ~toBD)
        {
            pieceCode(Style.bold[1]);
            if (toBD & FontStyle.bold)
                pieceCode(Style.bold[0]);
            if (toBD & FontStyle.dim)
                pieceCode(Style.dim[0]);
        }
        else
        {
            if ((toBD & FontStyle.bold) && !(fromBD & FontStyle.bold))
                pieceCode(Style.bold[0]);
            if ((toBD & FontStyle.dim) && !(fromBD & FontStyle.dim))
                pieceCode(Style.dim[0]);
        }
    }

    static struct FlagCodes
    {
        FontStyle flag;
        uint on, off;
    }

    static immutable FlagCodes[3] flagCodes = [
        FlagCodes(FontStyle.italic, Style.italic[0], Style.italic[1]),
        FlagCodes(FontStyle.underline, Style.underline[0], Style.underline[1]),
        FlagCodes(FontStyle.strikethrough, Style.strikethrough[0], Style.strikethrough[1]),
    ];

    foreach (fc; flagCodes)
    {
        const had = hasFont(from.font, fc.flag);
        const has = hasFont(to.font, fc.flag);
        if (had != has)
            pieceCode(has ? fc.on : fc.off);
    }

    if (from.fg != to.fg)
    {
        if (!first)
            put(w, ';');
        first = false;
        writeSgrColor(w, to.fg, depth, background: false);
    }
    if (from.bg != to.bg)
    {
        if (!first)
            put(w, ';');
        first = false;
        writeSgrColor(w, to.bg, depth, background: true);
    }

    put(w, 'm');
}

/**
Emits the SGR parameter(s) selecting `color` (without the `ESC[`/`m`
wrapper): `38;2;r;g;b` / `38;5;n` / classic codes by `depth`, `39`/`49` for
unset or terminal-default, palette entries kept palette-native (indices
0–15 as classic codes at any depth; 16–255 as `38;5;n`, downsampled through
the xterm palette only when the terminal can't address them).
*/
void writeSgrColor(Writer)(ref Writer w, in Color color, ColorDepth depth, bool background)
{
    final switch (color.kind)
    {
        case Color.Kind.unset:
        case Color.Kind.default_:
            put(w, background ? "49" : "39");
            return;

        case Color.Kind.palette:
            if (color.index < 16)
                writeClassicCode(w, color.index, background);
            else if (depth >= ColorDepth.ansi256)
            {
                put(w, background ? "48;5;" : "38;5;");
                writeInteger(w, color.index);
            }
            else
                writeClassicCode(w, ansi16FromRgb(xterm256ToRgb(color.index)), background);
            return;

        case Color.Kind.rgb:
            final switch (depth)
            {
                case ColorDepth.none:
                case ColorDepth.ansi16:
                    writeClassicCode(w, ansi16FromRgb(color.rgb), background);
                    return;
                case ColorDepth.ansi256:
                    put(w, background ? "48;5;" : "38;5;");
                    writeInteger(w, ansi256FromRgb(color.rgb));
                    return;
                case ColorDepth.trueColor:
                    put(w, background ? "48;2;" : "38;2;");
                    writeInteger(w, color.rgb.r);
                    put(w, ';');
                    writeInteger(w, color.rgb.g);
                    put(w, ';');
                    writeInteger(w, color.rgb.b);
                    return;
            }
    }
}

private void writeClassicCode(Writer)(ref Writer w, ubyte index, bool background)
in (index < 16)
{
    const base = index < 8
        ? (background ? 40 : 30) + index
        : (background ? 100 : 90) + index - 8;
    writeInteger(w, cast(uint) base);
}

version (unittest)
{
    import sparkles.base.smallbuffer : SmallBuffer, checkWriter;
    import sparkles.syntax.event : HighlightEvent, LabelId;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : Theme, ThemeRule, resolveTheme;

    // A tiny fixed vocabulary/theme pair shared by the renderer tests.
    private ResolvedTheme testTheme() @safe pure nothrow
    {
        const theme = Theme(
            name: "test",
            rules: [
                ThemeRule("keyword", StyleSpec(
                    fg: Color.fromRgb(0xcb, 0xa6, 0xf7), font: FontStyle.bold)),
                ThemeRule("string", StyleSpec(fg: Color.fromRgb(0xa6, 0xe3, 0xa1))),
                ThemeRule("comment", StyleSpec(
                    fg: Color.fromPalette(8), font: FontStyle.italic)),
            ]);
        return resolveTheme(theme, LabelSet.standard());
    }

    private LabelId lbl(string name) @safe pure nothrow
    {
        const id = LabelSet.standard().find(name);
        assert(id, name);
        return id;
    }
}

///
@("render.ansi.basicRuns")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "if (x) // hi";
    const events = [
        E.pushLabel(lbl("keyword")),
        E.sourceSpan(0, 2),
        E.popLabel(),
        E.sourceSpan(2, 7),
        E.pushLabel(lbl("comment")),
        E.sourceSpan(7, 12),
        E.popLabel(),
    ];

    // trueColor: bold+fg for the keyword; palette 8 stays palette-native
    // (classic bright-black 90) at every depth; comment italic gated off.
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.trueColor)))(
        "\x1b[1;38;2;203;166;247mif\x1b[0m (x) \x1b[90m// hi\x1b[0m");

    // ansi256: RGB folds to the nearest palette entry
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256)))(
        "\x1b[1;38;5;183mif\x1b[0m (x) \x1b[90m// hi\x1b[0m");

    // ansi16: RGB folds to the classic palette (0xcba6f7 → white, 37)
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi16)))(
        "\x1b[1;37mif\x1b[0m (x) \x1b[90m// hi\x1b[0m");

    // none: verbatim passthrough
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.none)))(source);
}

@("render.ansi.italicsGateAndBackground")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "x";
    const events = [
        E.pushLabel(lbl("comment")),
        E.sourceSpan(0, 1),
        E.popLabel(),
    ];

    // italics off (default): only the color survives
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256)))(
        "\x1b[90mx\x1b[0m");

    // italics on: italic flag emitted
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256, italics: true)))(
        "\x1b[3;90mx\x1b[0m");
}

@("render.ansi.adjacentRunsDiffMinimally")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "abcd";
    // keyword then string: same-bold? no — keyword is bold, string is not:
    // transition must clear bold (22) and change color in ONE sequence.
    const events = [
        E.pushLabel(lbl("keyword")),
        E.sourceSpan(0, 2),
        E.popLabel(),
        E.pushLabel(lbl("string")),
        E.sourceSpan(2, 4),
        E.popLabel(),
    ];

    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.trueColor)))(
        "\x1b[1;38;2;203;166;247mab\x1b[22;38;2;166;227;161mcd\x1b[0m");
}

@("render.ansi.perLineReset")
@safe pure nothrow
unittest
{
    import sparkles.base.text.ansi : SgrState, byAnsiToken;

    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "aa\nbb\ncc";
    const events = [
        E.pushLabel(lbl("string")),
        E.sourceSpan(0, 8), // one span across three lines
        E.popLabel(),
    ];

    SmallBuffer!(char, 256) buf;
    renderAnsi(source, events[], resolved, buf,
        AnsiOptions(depth: ColorDepth.trueColor));

    // style re-established after each newline
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.trueColor)))(
        "\x1b[38;2;166;227;161maa\x1b[0m\n\x1b[38;2;166;227;161mbb\x1b[0m\n" ~
        "\x1b[38;2;166;227;161mcc\x1b[0m");

    // the machine-checked invariant: SGR state inactive at every newline
    SgrState state;
    foreach (token; byAnsiToken(buf[]))
    {
        if (token.isEscape)
            state.apply(token.slice);
        else
        {
            foreach (char ch; token.slice)
                if (ch == '\n')
                    assert(!state.active, "styled newline leaked");
        }
    }
    assert(!state.active, "unterminated style at end of output");
}

@("render.ansi.nogcProof")
@safe pure nothrow @nogc
unittest
{
    // The whole render path is @nogc given @nogc inputs.
    static immutable HighlightEvent[3] events = [
        HighlightEvent.pushLabel(LabelId(0)),
        HighlightEvent.sourceSpan(0, 4),
        HighlightEvent.popLabel(),
    ];
    const ResolvedTheme theme; // empty: everything renders unstyled
    SmallBuffer!(char, 64) buf;
    renderAnsi("text", events[], theme, buf);
    assert(buf[] == "text");
}

@("render.ansi.writeSgrColor")
@safe pure nothrow @nogc
unittest
{
    checkWriter!((ref w) => writeSgrColor(w, Color.init, ColorDepth.trueColor, false))("39");
    checkWriter!((ref w) => writeSgrColor(w, Color.defaultColor, ColorDepth.trueColor, true))("49");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(3), ColorDepth.trueColor, false))("33");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(11), ColorDepth.ansi16, true))("103");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(114), ColorDepth.ansi256, false))("38;5;114");
    // palette above 15 at ansi16: downsampled through the xterm palette
    checkWriter!((ref w) => writeSgrColor(w, Color.fromPalette(196), ColorDepth.ansi16, false))("91");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(1, 2, 3), ColorDepth.trueColor, false))("38;2;1;2;3");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(255, 0, 0), ColorDepth.ansi256, true))("48;5;196");
    checkWriter!((ref w) => writeSgrColor(w, Color.fromRgb(255, 0, 0), ColorDepth.ansi16, false))("91");
}

@("render.ansi.writeStyleTransition")
@safe pure nothrow @nogc
unittest
{
    const bold = StyleSpec(font: FontStyle.bold);
    const boldDim = StyleSpec(font: cast(FontStyle)(FontStyle.bold | FontStyle.dim));
    const dim = StyleSpec(font: FontStyle.dim);
    const plainRed = StyleSpec(fg: Color.fromPalette(1));

    // no-op
    checkWriter!((ref w) => writeStyleTransition(w, bold, bold, ColorDepth.ansi256))("");
    // to empty → single reset
    checkWriter!((ref w) => writeStyleTransition(w, bold, StyleSpec.init, ColorDepth.ansi256))("\x1b[0m");
    // from empty
    checkWriter!((ref w) => writeStyleTransition(w, StyleSpec.init, bold, ColorDepth.ansi256))("\x1b[1m");
    // bold→dim: 22 clears both, dim re-issued
    checkWriter!((ref w) => writeStyleTransition(w, bold, dim, ColorDepth.ansi256))("\x1b[22;2m");
    // bold→bold+dim: pure addition, no 22
    checkWriter!((ref w) => writeStyleTransition(w, bold, boldDim, ColorDepth.ansi256))("\x1b[2m");
    // bold+dim→bold: 22 then re-issue bold
    checkWriter!((ref w) => writeStyleTransition(w, boldDim, bold, ColorDepth.ansi256))("\x1b[22;1m");
    // color-only change
    checkWriter!((ref w) => writeStyleTransition(w, StyleSpec.init, plainRed, ColorDepth.ansi256))("\x1b[31m");
    // dropping the color while keeping nothing else → reset
    checkWriter!((ref w) => writeStyleTransition(w, plainRed, StyleSpec.init, ColorDepth.ansi256))("\x1b[0m");
}
