/**
The HTML rendering backend: folds a highlight-event stream into `span`
markup.

Consumes the $(B raw) event stream (nesting preserved — nested labels become
nested tags) in two modes: $(LREF HtmlMode.inlineStyles) (self-contained
`style="…"` attributes) and $(LREF HtmlMode.cssClasses) (label-derived class
names, dots → dashes: `string.special.key` → `class="syn-string-special-key"`,
styled by a $(LREF writeThemeStylesheet) stylesheet). A CSS-variables
multi-theme mode (the Shiki doctrine) is a planned third mode.

$(B Per-line validity:) at every `'\n'` all open tags are closed and
re-opened after it (the reference tree-sitter `HtmlRenderer` rule), so each
output line is independently valid markup.

The output is $(B content only) — no `pre`/`code` wrapper; wrapping is the
caller's job (pair `cssClasses` output with the stylesheet's `syn-root`
rule). Source text is escaped with `sparkles.base.text.html.writeHtmlEscaped`.
Totality: the renderer never fails on any event stream.

Color notes: `Color.Kind.palette` values are concretized through the xterm
default palette (`xterm256ToRgb`) — HTML has no terminal palette to defer
to; `default_`/`unset` emit no declaration; `TextAttr.dim` has no single
CSS declaration and is skipped.
*/
module sparkles.syntax.render.html;

import std.range.primitives : empty, front, popFront, put;

import sparkles.base.text.html : writeHtmlEscaped;
import sparkles.base.text.writers : writeHexByte;

import sparkles.syntax.color : Color, RgbColor, xterm256ToRgb;
import sparkles.syntax.event : HighlightEvent, LabelId, isHighlightEventRange;
import sparkles.syntax.theme : ResolvedTheme, StyleSpec, TextAttr, UnderlineStyle;

import sparkles.base.smallbuffer : SmallBuffer;

/// How $(LREF renderHtml) expresses styles.
enum HtmlMode : ubyte
{
    inlineStyles, /// `<span style="color:#…">` — self-contained output
    cssClasses,   /// `<span class="syn-…">` — style via a stylesheet
}

/// Options for $(LREF renderHtml).
struct HtmlOptions
{
    HtmlMode mode = HtmlMode.inlineStyles; /// see $(LREF HtmlMode)
    const(char)[] classPrefix = "syn-";    /// class-name prefix (`cssClasses`)
}

/**
Folds `events` over `source`, writing highlighted HTML content to `w`.

`w` is any `char` output range. Attributes infer: with a `@nogc` writer and
event range the whole render path is `@safe pure nothrow @nogc`.
*/
ref Writer renderHtml(Writer, Events)(
    scope const(char)[] source,
    Events events,
    in ResolvedTheme theme,
    return ref Writer w,
    in HtmlOptions options = HtmlOptions(),
)
if (isHighlightEventRange!Events)
{
    import std.algorithm.comparison : min;
    import std.algorithm.searching : countUntil;
    import std.utf : byCodeUnit;

    static struct OpenSpan
    {
        LabelId label;
        bool emitted;
    }

    SmallBuffer!(OpenSpan, 16) stack;

    // Writes the opening tag for `label` if it produces one; returns whether
    // a tag was written (its pop/reopen must mirror the decision).
    bool writeOpenTag(LabelId label)
    {
        final switch (options.mode)
        {
            case HtmlMode.inlineStyles:
            {
                const spec = theme[label];
                if (spec.empty)
                    return false;
                put(w, `<span style="`);
                writeStyleDeclarations(w, spec);
                put(w, `">`);
                return true;
            }
            case HtmlMode.cssClasses:
            {
                if (!label || label.value >= theme.labels.length)
                    return false;
                put(w, `<span class="`);
                put(w, options.classPrefix);
                writeClassName(w, theme.labels.name(label));
                put(w, `">`);
                return true;
            }
        }
    }

    void closeOpenTags()
    {
        foreach_reverse (i; 0 .. stack.length)
            if (stack[i].emitted)
                put(w, "</span>");
    }

    void reopenTags()
    {
        foreach (i; 0 .. stack.length)
            if (stack[i].emitted)
                cast(void) writeOpenTag(stack[i].label);
    }

    while (!events.empty)
    {
        const ev = events.front;
        events.popFront();
        final switch (ev.kind)
        {
            case HighlightEvent.Kind.push:
                stack ~= OpenSpan(ev.label, writeOpenTag(ev.label));
                break;

            case HighlightEvent.Kind.pop:
                if (stack.length)
                {
                    if (stack[stack.length - 1].emitted)
                        put(w, "</span>");
                    stack.popBack();
                }
                break;

            case HighlightEvent.Kind.source:
            {
                // Defensive clamp, same posture as the ANSI renderer.
                const lo = min(ev.start, source.length);
                const hi = min(ev.end, source.length);
                const(char)[] text = lo < hi ? source[lo .. hi] : null;

                while (text.length)
                {
                    const nlPos = text.byCodeUnit.countUntil('\n');
                    if (nlPos < 0)
                    {
                        writeHtmlEscaped(w, text);
                        break;
                    }

                    const nl = cast(size_t) nlPos;
                    writeHtmlEscaped(w, text[0 .. nl]);
                    closeOpenTags();
                    put(w, '\n');
                    reopenTags();
                    text = text[nl + 1 .. $];
                }
                break;
            }
        }
    }

    // Defensive: unbalanced pushes must not leak unclosed tags.
    closeOpenTags();
    return w;
}

/**
Writes one CSS rule per styled label of `theme` (class names as in
$(LREF renderHtml)'s `cssClasses` mode), preceded by a `<prefix>root` rule
carrying the theme's default fore-/background when set — pair it with a
`class="<prefix>root"` wrapper element.
*/
ref Writer writeThemeStylesheet(Writer)(in ResolvedTheme theme, return ref Writer w,
    scope const(char)[] classPrefix = "syn-")
{
    if (!theme.defaults.empty)
    {
        put(w, '.');
        put(w, classPrefix);
        put(w, "root{");
        writeStyleDeclarations(w, theme.defaults);
        put(w, "}\n");
    }
    foreach (i; 0 .. theme.labels.length)
    {
        const spec = theme.styles[i];
        if (spec.empty)
            continue;
        put(w, '.');
        put(w, classPrefix);
        writeClassName(w, theme.labels.name(LabelId(cast(ushort) i)));
        put(w, '{');
        writeStyleDeclarations(w, spec);
        put(w, "}\n");
    }
    return w;
}

/// Writes `spec` as `;`-separated CSS declarations (no trailing `;`).
private void writeStyleDeclarations(Writer)(ref Writer w, in StyleSpec spec)
{
    bool first = true;

    void sep()
    {
        if (!first)
            put(w, ';');
        first = false;
    }

    RgbColor rgb;
    if (concreteRgb(spec.fg, rgb))
    {
        sep();
        put(w, "color:#");
        writeHexRgb(w, rgb);
    }
    if (concreteRgb(spec.bg, rgb))
    {
        sep();
        put(w, "background-color:#");
        writeHexRgb(w, rgb);
    }
    if (spec.attrs.has(TextAttr.bold))
    {
        sep();
        put(w, "font-weight:bold");
    }
    if (spec.attrs.has(TextAttr.italic))
    {
        sep();
        put(w, "font-style:italic");
    }
    const underline = spec.underline != UnderlineStyle.none;
    const strikethrough = spec.attrs.has(TextAttr.strikethrough);
    if (underline || strikethrough)
    {
        sep();
        put(w, "text-decoration:");
        if (underline)
            put(w, "underline");
        if (underline && strikethrough)
            put(w, ' ');
        if (strikethrough)
            put(w, "line-through");
    }
    // Non-single underline shapes map to CSS text-decoration-style; an underline
    // color maps to text-decoration-color. Solid single underlines emit neither
    // (the CSS defaults), so existing output is unchanged.
    if (underline && spec.underline != UnderlineStyle.single)
    {
        sep();
        put(w, "text-decoration-style:");
        final switch (spec.underline)
        {
            case UnderlineStyle.none:
            case UnderlineStyle.single:  break; // unreachable under the guard
            case UnderlineStyle.double_: put(w, "double"); break;
            case UnderlineStyle.curly:   put(w, "wavy");   break;
            case UnderlineStyle.dotted:  put(w, "dotted"); break;
            case UnderlineStyle.dashed:  put(w, "dashed"); break;
        }
    }
    if (underline && concreteRgb(spec.underlineColor, rgb))
    {
        sep();
        put(w, "text-decoration-color:#");
        writeHexRgb(w, rgb);
    }
}

/// `true` iff `c` concretizes to an RGB value (rgb directly; palette through
/// the xterm defaults).
private bool concreteRgb(in Color c, out RgbColor rgb) @safe pure nothrow @nogc
{
    final switch (c.kind)
    {
        case Color.Kind.unset:
        case Color.Kind.default_:
            return false;
        case Color.Kind.palette:
            rgb = xterm256ToRgb(c.index);
            return true;
        case Color.Kind.rgb:
            rgb = c.rgb;
            return true;
    }
}

private void writeClassName(Writer)(ref Writer w, scope const(char)[] labelName)
{
    foreach (char c; labelName)
        put(w, c == '.' ? '-' : c);
}

private void writeHexRgb(Writer)(ref Writer w, in RgbColor c)
{
    writeHexByte(w, c.r);
    writeHexByte(w, c.g);
    writeHexByte(w, c.b);
}

version (unittest)
{
    import sparkles.base.smallbuffer : checkWriter;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : Theme, ThemeRule, resolveTheme;

    private ResolvedTheme testTheme() @safe pure nothrow
    {
        const theme = Theme(
            name: "test",
            rules: [
                ThemeRule("keyword", StyleSpec(
                    fg: Color.fromRgb(0xcb, 0xa6, 0xf7), attrs: TextAttr.bold)),
                ThemeRule("string", StyleSpec(fg: Color.fromRgb(0xa6, 0xe3, 0xa1))),
                ThemeRule("comment", StyleSpec(
                    fg: Color.fromPalette(8), attrs: TextAttr.italic)),
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
@("render.html.inlineStyles")
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

    checkWriter!((ref w) => renderHtml(source, events[], resolved, w))(
        `<span style="color:#cba6f7;font-weight:bold">if</span> (x) ` ~
        `<span style="color:#7f7f7f;font-style:italic">// hi</span>`);
}

/// Non-single underline shapes and an underline color render to CSS
/// text-decoration-style / text-decoration-color.
@("render.html.underlineStyleAndColor")
@safe pure nothrow
unittest
{
    import sparkles.syntax.theme : Theme, ThemeRule, resolveTheme;

    alias E = HighlightEvent;
    const theme = Theme(name: "t", rules: [
        ThemeRule("keyword", StyleSpec(
            underlineColor: Color.fromRgb(0xff, 0x55, 0x55),
            underline: UnderlineStyle.curly)),
    ]);
    const resolved = resolveTheme(theme, LabelSet.standard());
    const source = "if";
    const events = [E.pushLabel(lbl("keyword")), E.sourceSpan(0, 2), E.popLabel()];

    checkWriter!((ref w) => renderHtml(source, events[], resolved, w))(
        `<span style="text-decoration:underline;text-decoration-style:wavy;` ~
        `text-decoration-color:#ff5555">if</span>`);
}

@("render.html.cssClasses")
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

    checkWriter!((ref w) => renderHtml(source, events[], resolved, w,
        HtmlOptions(mode: HtmlMode.cssClasses)))(
        `<span class="syn-keyword">if</span> (x) <span class="syn-comment">// hi</span>`);
}

@("render.html.nestedSpansAndDottedClasses")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = `"a\n"`;
    const events = [
        E.pushLabel(lbl("string")),
        E.sourceSpan(0, 2),
        E.pushLabel(lbl("constant.character.escape")),
        E.sourceSpan(2, 4),
        E.popLabel(),
        E.sourceSpan(4, 5),
        E.popLabel(),
    ];

    // constant.character.escape has no styled rule in the test theme →
    // inline mode: no tag for it, text still nested in the string span
    checkWriter!((ref w) => renderHtml(source, events[], resolved, w))(
        `<span style="color:#a6e3a1">&quot;a\n&quot;</span>`);

    // class mode: every real label gets a class, dots → dashes
    checkWriter!((ref w) => renderHtml(source, events[], resolved, w,
        HtmlOptions(mode: HtmlMode.cssClasses)))(
        `<span class="syn-string">&quot;a` ~
        `<span class="syn-constant-character-escape">\n</span>` ~
        `&quot;</span>`);
}

@("render.html.perLineValidity")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    alias E = HighlightEvent;
    const source = "aa\nbb\ncc";
    const events = [
        E.pushLabel(lbl("string")),
        E.sourceSpan(0, 8),
        E.popLabel(),
    ];

    checkWriter!((ref w) => renderHtml(source, events[], resolved, w))(
        "<span style=\"color:#a6e3a1\">aa</span>\n" ~
        "<span style=\"color:#a6e3a1\">bb</span>\n" ~
        "<span style=\"color:#a6e3a1\">cc</span>");

    // the machine-checked invariant: balanced tags on every line
    SmallBuffer!(char, 512) buf;
    renderHtml(source, events[], resolved, buf,
        HtmlOptions(mode: HtmlMode.cssClasses));
    size_t open, close;
    foreach (i, char c; buf[])
    {
        if (c == '\n')
        {
            assert(open == close, "unbalanced spans on a line");
            open = close = 0;
        }
        else if (c == '<' && i + 1 < buf.length)
        {
            if (buf[i + 1] == '/')
                ++close;
            else
                ++open;
        }
    }
    assert(open == close, "unbalanced spans on the last line");
}

@("render.html.escaping")
@safe pure nothrow
unittest
{
    const resolved = testTheme();
    const source = `a<b&"c"`;
    const events = [HighlightEvent.sourceSpan(0, 7)];

    checkWriter!((ref w) => renderHtml(source, events[], resolved, w))(
        "a&lt;b&amp;&quot;c&quot;");
}

@("render.html.nogcProof")
@safe pure nothrow @nogc
unittest
{
    static immutable HighlightEvent[3] events = [
        HighlightEvent.pushLabel(LabelId(0)),
        HighlightEvent.sourceSpan(0, 4),
        HighlightEvent.popLabel(),
    ];
    const ResolvedTheme theme; // empty: everything renders unstyled
    SmallBuffer!(char, 64) buf;
    renderHtml("text", events[], theme, buf);
    assert(buf[] == "text");
}

@("render.html.writeThemeStylesheet")
@safe pure nothrow
unittest
{
    import sparkles.syntax.color : parseHexColor;

    static Color hex(string s) @safe pure nothrow @nogc
    {
        const(char)[] t = s;
        return parseHexColor(t).value;
    }

    const theme = Theme(
        name: "test",
        defaultFg: hex("#cdd6f4"),
        defaultBg: hex("#1e1e2e"),
        rules: [
            ThemeRule("keyword", StyleSpec(
                fg: Color.fromRgb(0xcb, 0xa6, 0xf7), attrs: TextAttr.bold)),
            ThemeRule("string", StyleSpec(fg: Color.fromRgb(0xa6, 0xe3, 0xa1))),
        ]);
    const resolved = resolveTheme(theme, LabelSet.fromNames(["keyword", "string"]));

    checkWriter!((ref w) => writeThemeStylesheet(resolved, w))(
        ".syn-root{color:#cdd6f4;background-color:#1e1e2e}\n" ~
        ".syn-keyword{color:#cba6f7;font-weight:bold}\n" ~
        ".syn-string{color:#a6e3a1}\n");
}
