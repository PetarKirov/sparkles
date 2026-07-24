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

import sparkles.base.text.ansi : writeSgrReset;
import sparkles.base.term_control : CtlSeq;
import sparkles.base.term_style : writeStyleTransition;

import sparkles.syntax.color : Color, ColorDepth;
import sparkles.syntax.event : byStyledSpan, isHighlightEventRange;
import sparkles.syntax.theme : TextAttr, ResolvedTheme, StyleSpec;

/// Options for $(LREF renderAnsi).
struct AnsiOptions
{
    /// Color tier to emit. `none` = verbatim passthrough.
    ColorDepth depth = ColorDepth.ansi256;

    /// Emit per-run theme backgrounds — including the theme's page
    /// background (`ResolvedTheme.defaults.bg`) for runs whose own rule
    /// styles fg only. Off by default: respect the terminal's own
    /// background.
    bool emitBackground = false;

    /// Emit italics. Off by default (bat's defensive gate — some terminals
    /// render italics poorly); italic font flags are dropped when off.
    bool italics = false;

    /// Fill every line to the terminal's right edge with the theme's page
    /// background (`ResolvedTheme.defaults.bg`), by emitting `EL`
    /// (erase-to-end-of-line) before each newline so back-color-erase paints
    /// the remainder of the line edge-to-edge. Off by default. Requires
    /// `emitBackground`; gives whole-file output the same uninterrupted
    /// backdrop as an alt-screen previewer, instead of the background stopping
    /// at each line's last glyph.
    bool fillLine = false;
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
            // Reset-to-default is a single `ESC[0m` (a renderer-level choice that
            // keeps each line self-contained); any other change is the minimal
            // group diff from the shared encoder.
            if (target.empty)
                writeSgrReset(w);
            else
                writeStyleTransition(w, current, target, options.depth);
            current = target;
        }
    }

    // Full-line fill (BGM `full`): before terminating a line, open just the
    // page background and erase to the right edge, so back-color-erase paints
    // the rest of the line — including empty lines and the region past the
    // last glyph — with the theme backdrop.
    void fillToEol()
    {
        transitionTo(StyleSpec(bg: theme.defaults.bg));
        put(w, cast(string) CtlSeq.eraseToEnd);
    }

    bool pendingLine = false; // content on the current line, not yet terminated

    foreach (span; byStyledSpan(events))
    {
        auto spec = theme[span.label];
        if (!options.italics)
            spec.attrs = spec.attrs & ~TextAttr.italic;
        if (!options.emitBackground)
            spec.bg = Color.init;
        else if (!spec.bg.isSet)
            // Most rules style fg only. Unlike HTML's `<pre>` container,
            // ANSI has no background inheritance, so without this an unset
            // per-span bg would render as the terminal's own default (`49`)
            // instead of the theme's page background showing through.
            spec.bg = theme.defaults.bg;

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
                pendingLine = true;
                break;
            }

            const nl = cast(size_t) nlPos;
            if (nl > 0)
            {
                transitionTo(spec);
                put(w, text[0 .. nl]);
            }
            if (options.fillLine)
                fillToEol();
            // reset before the newline; re-open lazily at the next text
            transitionTo(StyleSpec.init);
            put(w, '\n');
            pendingLine = false;
            text = text[nl + 1 .. $];
        }
    }

    // The last line has no trailing newline of its own to hang the fill on.
    if (pendingLine && options.fillLine)
        fillToEol();
    transitionTo(StyleSpec.init);
    return w;
}

version (unittest)
{
    import sparkles.base.smallbuffer : SmallBuffer, checkWriter;
    import sparkles.syntax.event : HighlightEvent, LabelId;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : Theme, ThemeRule, resolveTheme;

    // Named test palette — so the theme rules and the expected-output SGR below
    // read as intent instead of bare magic hex/indices.
    private enum Color kwFg = Color.fromRgb(0xcb, 0xa6, 0xf7); // keyword (mauve)
    private enum Color strFg = Color.fromRgb(0xa6, 0xe3, 0xa1); // string (green)
    private enum Color commentFg = Color.fromPalette(8); // comment (bright black)
    private enum Color pageBg = Color.fromPalette(235); // page background

    // The SGR *parameters* the renderer emits for those colors, per depth.
    // (These can't be built with `styledText`: renderAnsi merges params into a
    // single escape — `\x1b[1;38;2;…m` — while styledText emits one escape per
    // style, so the byte streams differ.)
    private enum kwFgTrue = "38;2;203;166;247"; // kwFg at trueColor
    private enum kwFg256 = "38;5;183"; // kwFg folded to 256-palette
    private enum kwFg16 = "37"; // kwFg folded to classic-16 (white)
    private enum strFgTrue = "38;2;166;227;161"; // strFg at trueColor
    private enum commentSgr = "90"; // palette 8, classic bright-black at any depth
    private enum pageBg256 = "48;5;235"; // pageBg at 256-palette

    // A tiny fixed vocabulary/theme pair shared by the renderer tests.
    private ResolvedTheme testTheme() @safe pure nothrow
    {
        const theme = Theme(
            name: "test",
            defaultBg: pageBg, // only consulted with emitBackground
            rules: [
                ThemeRule("keyword", StyleSpec(fg: kwFg, attrs: TextAttr.bold)),
                ThemeRule("string", StyleSpec(fg: strFg)),
                ThemeRule("comment", StyleSpec(fg: commentFg, attrs: TextAttr.italic)),
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
        "\x1b[1;" ~ kwFgTrue ~ "mif\x1b[0m (x) \x1b[" ~ commentSgr ~ "m// hi\x1b[0m");

    // ansi256: RGB folds to the nearest palette entry
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256)))(
        "\x1b[1;" ~ kwFg256 ~ "mif\x1b[0m (x) \x1b[" ~ commentSgr ~ "m// hi\x1b[0m");

    // ansi16: RGB folds to the classic palette (kwFg → white, 37)
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi16)))(
        "\x1b[1;" ~ kwFg16 ~ "mif\x1b[0m (x) \x1b[" ~ commentSgr ~ "m// hi\x1b[0m");

    // none: verbatim passthrough
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.none)))(source);
}

@("render.ansi.emitBackgroundFallsBackToPageBackground")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "if x";
    const events = [
        E.pushLabel(lbl("keyword")),
        E.sourceSpan(0, 2), // "if" — the keyword rule styles fg only
        E.popLabel(),
        E.sourceSpan(2, 4), // " x" — unlabeled gap
    ];

    // "if" has no rule-specified background, but still picks up the theme's
    // page background (48;5;235) instead of resetting to the terminal
    // default; the unlabeled gap already carried it via `defaults`, so no
    // redundant background code is re-emitted when the run changes.
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256, emitBackground: true)))(
        "\x1b[1;" ~ kwFg256 ~ ";" ~ pageBg256 ~ "mif\x1b[22;39m x\x1b[0m");

    // emitBackground off (default): no page background leaks in at all.
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256)))(
        "\x1b[1;" ~ kwFg256 ~ "mif\x1b[0m x");
}

@("render.ansi.fillLineErasesToEol")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    // Two lines, unlabeled: every glyph and the region past it should carry the
    // page background. `fillLine` emits `EL` (erase-to-end-of-line) under the
    // page bg before each newline and on the trailing content line.
    const source = "a\nb";
    const events = [E.sourceSpan(0, source.length)];

    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256, emitBackground: true, fillLine: true)))(
        "\x1b[" ~ pageBg256 ~ "ma\x1b[0K\x1b[0m\n" ~
        "\x1b[" ~ pageBg256 ~ "mb\x1b[0K\x1b[0m");

    // Without fillLine the background stops at the last glyph — no `EL`.
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256, emitBackground: true)))(
        "\x1b[" ~ pageBg256 ~ "ma\x1b[0m\n\x1b[" ~ pageBg256 ~ "mb\x1b[0m");
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
        "\x1b[" ~ commentSgr ~ "mx\x1b[0m");

    // italics on: italic flag emitted
    checkWriter!((ref w) => renderAnsi(source, events[], resolved, w,
        AnsiOptions(depth: ColorDepth.ansi256, italics: true)))(
        "\x1b[3;" ~ commentSgr ~ "mx\x1b[0m");
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
        "\x1b[1;" ~ kwFgTrue ~ "mab\x1b[22;" ~ strFgTrue ~ "mcd\x1b[0m");
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
        "\x1b[" ~ strFgTrue ~ "maa\x1b[0m\n\x1b[" ~ strFgTrue ~ "mbb\x1b[0m\n" ~
        "\x1b[" ~ strFgTrue ~ "mcc\x1b[0m");

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
