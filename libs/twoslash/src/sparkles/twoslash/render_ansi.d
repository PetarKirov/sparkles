/**
The ANSI twoslash overlay: renders a highlighted snippet to the terminal with
its twoslash decorations as $(B meta-lines below the code) — the classic
`twoslash` `lineQuery`/`lineError` shape, which maps perfectly to a terminal
and which $(B nobody ships) (the differentiator of issue #123).

Per source line: the code is rendered through
$(REF renderAnsi, sparkles,syntax,render,ansi) (per-line-valid SGR already),
with any $(D highlight)/$(D error) span bracketed in reverse-video / underline;
then the below-line blocks are emitted — a caret row (`^^^` / `^?`) pointing at
the column, followed by the error message, the re-highlighted query type, the
completion candidates, or the `// @tag` text. Hovers are silent by default and
expand to a `↳ type` line under $(D TwoslashAnsiOptions.hovers) (the CLI
convention — inline hover noise helps no one).

`@system` (reentrant highlight) and not `@nogc` (it allocates).
*/
module sparkles.twoslash.render_ansi;

import std.range.primitives : put;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.syntax.color : ColorDepth;
import sparkles.syntax.event : byStyledLine, HighlightEvent, LabelId, StyledLineSpan;
import sparkles.syntax.render.ansi : renderAnsi, AnsiOptions;
import sparkles.syntax.theme : ResolvedTheme;
import sparkles.syntax.ts.injection : TsConfigCache;

import sparkles.base.term_color : ColorChannel;
import sparkles.ui.style : defaultTwoslashPalette, Palette, Slot, writeSlotSgr;

import sparkles.twoslash.overlay : BelowBlock, errIsWarning, highlightSignature,
    InlineDecoration, planTwoslash, TwoslashPlan;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;

/// Options for $(LREF renderTwoslashAnsi).
struct TwoslashAnsiOptions
{
    ColorDepth depth = ColorDepth.ansi256; /// color tier for the code; `none` = plain
    bool italics = false;      /// pass through to the code renderer
    bool emitBackground = false; /// pass through to the code renderer
    bool hovers = false;       /// expand hovers as `↳ type` meta-lines
}

// Meta-chrome *attributes* stay terminal-native (dim/reverse/underline are not
// brand colors). The brand *colors* (error/warn/tag) come from the single-source
// twoslash palette via `slotFgSeq`, so all three backends agree — at `depth`,
// the palette color downsamples to the terminal's tier (truecolor → exact,
// ansi256/16 → nearest).
private enum sgrReset = "\x1b[0m";
private enum sgrDim = "\x1b[2m";
private enum sgrReverse = "\x1b[7m";
private enum sgrReverseOff = "\x1b[27m";
private enum sgrUnderline = "\x1b[4m";
private enum sgrUnderlineOff = "\x1b[24m";

/// Builds the `ESC[…m` foreground sequence selecting `slot` from `pal` at
/// `depth`, into `buf` (returns its slice — valid until `buf` is next reused).
private const(char)[] slotFgSeq(ref SmallBuffer!(char, 32) buf, in Palette pal,
    Slot slot, ColorDepth depth) @safe
{
    buf.clear();
    buf ~= "\x1b[";
    writeSlotSgr(buf, pal, slot, ColorChannel.foreground, depth);
    buf ~= "m";
    return buf[];
}

/**
Renders `tw` (its `code` already highlighted into `events`) as the ANSI
twoslash overlay into `w`. `cache` drives the reentrant re-highlight of query
type signatures.
*/
ref Writer renderTwoslashAnsi(Writer)(
    in TwoslashReturn tw,
    scope const(HighlightEvent)[] events,
    in ResolvedTheme theme,
    ref TsConfigCache cache,
    return ref Writer w,
    in TwoslashAnsiOptions options = TwoslashAnsiOptions(),
) @system
{
    const code = tw.code;
    auto plan = planTwoslash(tw);
    const decos = plan.inlineDecorations;
    const below = plan.belowBlocks;
    const styled = options.depth != ColorDepth.none;
    const pal = defaultTwoslashPalette();

    // Materialize per-line styled runs (absolute byte offsets, clipped to line).
    SmallBuffer!StyledLineSpan lineRuns;
    foreach (ls; byStyledLine(code, events))
        lineRuns ~= ls;

    const ansiOpts = AnsiOptions(depth: options.depth, italics: options.italics,
        emitBackground: options.emitBackground);

    // Renders code[p .. q] with the line's syntax runs, offset into the slice.
    void renderSlice(size_t p, size_t q)
    {
        if (p >= q)
            return;
        SmallBuffer!HighlightEvent ev;
        size_t cur = p;
        foreach (ref const ls; lineRuns[])
        {
            const s = ls.span.start, e = ls.span.end;
            if (e <= p || s >= q)
                continue;
            const a = s < p ? p : s, b = e > q ? q : e;
            if (cur < a)
                ev ~= HighlightEvent.sourceSpan(cur - p, a - p);
            if (ls.span.label)
            {
                ev ~= HighlightEvent.pushLabel(ls.span.label);
                ev ~= HighlightEvent.sourceSpan(a - p, b - p);
                ev ~= HighlightEvent.popLabel();
            }
            else
                ev ~= HighlightEvent.sourceSpan(a - p, b - p);
            cur = b;
        }
        if (cur < q)
            ev ~= HighlightEvent.sourceSpan(cur - p, q - p);
        renderAnsi(code[p .. q], ev[], theme, w, ansiOpts);
    }

    size_t lineStart = 0;
    size_t line = 0;
    // Walk the code line by line (a line is code[lineStart .. lineEnd), '\n' excl).
    while (lineStart <= code.length)
    {
        size_t lineEnd = lineStart;
        while (lineEnd < code.length && code[lineEnd] != '\n')
            ++lineEnd;

        // Inline decorations on this line, split at their boundaries.
        renderCodeLine(w, code, lineStart, lineEnd, decos, line, styled, &renderSlice);

        // Terminate the code line (all lines except a trailing empty tail).
        if (lineEnd < code.length)
            put(w, '\n');

        // Below-line meta blocks anchored to this line.
        foreach (ref const b; below[])
            if (b.line == line)
                writeMeta(w, theme, cache, tw.effectiveLanguage, pal, tw.nodes[b.node], styled, options);

        // Hover expansion (opt-in): a `↳ type` line under the hovered token.
        if (options.hovers)
            foreach (ref const d; decos)
                if (d.kind == NodeType.hover && d.line == line)
                    writeHover(w, theme, cache, tw.effectiveLanguage, tw.nodes[d.node], d, styled);

        if (lineEnd >= code.length)
            break;
        lineStart = lineEnd + 1;
        ++line;
    }

    // Trailing below-blocks anchored past the final code line — twoslash gives a
    // trailing `@tag`/query a line index one past the end. Flush them below the
    // code (sorted by line, so this preserves their order).
    foreach (ref const b; below[])
        if (b.line > line)
            writeMeta(w, theme, cache, tw.effectiveLanguage, pal, tw.nodes[b.node], styled, options);

    return w;
}

/// Renders one code line, bracketing highlight/error spans in reverse/underline.
private void renderCodeLine(Writer)(ref Writer w, scope const(char)[] code,
    size_t lineStart, size_t lineEnd, const(InlineDecoration)[] decos, size_t line,
    bool styled, scope void delegate(size_t, size_t) @system renderSlice) @system
{
    // Cut points: line bounds plus every decoration edge inside the line.
    SmallBuffer!size_t cuts;
    cuts ~= lineStart;
    foreach (ref const d; decos)
    {
        if (d.line != line || d.kind == NodeType.hover)
            continue;
        if (d.start > lineStart && d.start < lineEnd)
            cuts ~= d.start;
        if (d.end > lineStart && d.end < lineEnd)
            cuts ~= d.end;
    }
    cuts ~= lineEnd;
    sortUnique(cuts);

    foreach (i; 0 .. (cuts.length ? cuts.length - 1 : 0))
    {
        const p = cuts[i], q = cuts[i + 1];
        // Which decoration (if any) covers this whole segment?
        bool reverse, underline;
        foreach (ref const d; decos)
        {
            if (d.line != line || d.kind == NodeType.hover)
                continue;
            if (d.start <= p && d.end >= q && d.start < d.end)
            {
                if (d.kind == NodeType.highlight)
                    reverse = true;
                else if (d.kind == NodeType.error)
                    underline = true;
            }
        }
        if (styled && reverse)
            put(w, sgrReverse);
        if (styled && underline)
            put(w, sgrUnderline);
        renderSlice(p, q);
        if (styled && underline)
            put(w, sgrUnderlineOff);
        if (styled && reverse)
            put(w, sgrReverseOff);
    }
}

/// A below-line meta block: caret row + payload. Brand colors (error/warn/tag)
/// come from `pal` via $(LREF slotFgSeq); `dim` completion de-emphasis stays a
/// terminal attribute.
private void writeMeta(Writer)(ref Writer w, in ResolvedTheme theme, ref TsConfigCache cache,
    scope const(char)[] language, in Palette pal, in Node node, bool styled,
    in TwoslashAnsiOptions options) @system
{
    SmallBuffer!(char, 32) seqBuf;
    final switch (node.type)
    {
        case NodeType.error:
            const seq = styled
                ? slotFgSeq(seqBuf, pal, errIsWarning(node.level) ? Slot.warn : Slot.error, options.depth)
                : "";
            writeCaret(w, node.character, node.length ? node.length : 1, seq, styled);
            writeIndented(w, node.character, node.text, seq, styled);
            break;

        case NodeType.query:
            writeCaret(w, node.character, 2,
                styled ? slotFgSeq(seqBuf, pal, Slot.info, options.depth) : "", styled, "^?");
            // Re-highlight the query type signature, indented under the caret.
            writeSpaces(w, node.character);
            SmallBuffer!HighlightEvent sig;
            highlightSignature(cache, language, node.text, sig);
            renderAnsi(node.text, sig[], theme, w,
                AnsiOptions(depth: styled ? options.depth : ColorDepth.none,
                    italics: options.italics));
            put(w, '\n');
            break;

        case NodeType.completion:
            writeCaret(w, node.character, 1, styled ? sgrDim : "", styled);
            foreach (ref const Completion c; node.completions)
            {
                writeSpaces(w, node.character);
                if (styled)
                    put(w, sgrDim);
                put(w, "- ");
                put(w, c.name);
                if (styled)
                    put(w, sgrReset);
                put(w, '\n');
            }
            break;

        case NodeType.tag:
            writeSpaces(w, node.character);
            if (styled)
                put(w, slotFgSeq(seqBuf, pal, Slot.info, options.depth));
            put(w, "@");
            put(w, node.name);
            if (node.text.length)
            {
                put(w, ' ');
                put(w, node.text);
            }
            if (styled)
                put(w, sgrReset);
            put(w, '\n');
            break;

        case NodeType.hover:
        case NodeType.highlight:
            break; // handled inline / via writeHover
    }
}

/// The opt-in hover expansion: `↳ type` under the hovered token.
private void writeHover(Writer)(ref Writer w, in ResolvedTheme theme, ref TsConfigCache cache,
    scope const(char)[] language, in Node node, in InlineDecoration d, bool styled) @system
{
    writeSpaces(w, d.character);
    if (styled)
        put(w, sgrDim);
    put(w, "↳ "); // ↳
    if (styled)
        put(w, sgrReset);
    SmallBuffer!HighlightEvent sig;
    highlightSignature(cache, language, node.text, sig);
    renderAnsi(node.text, sig[], theme, w,
        AnsiOptions(depth: styled ? ColorDepth.ansi256 : ColorDepth.none));
    put(w, '\n');
}

/// A caret row: `col` spaces then `width` copies of the caret glyph (default `^`).
private void writeCaret(Writer)(ref Writer w, size_t col, size_t width,
    scope const(char)[] color, bool styled, scope const(char)[] glyph = "^") @safe
{
    writeSpaces(w, col);
    if (styled && color.length)
        put(w, color);
    if (glyph == "^")
        foreach (_; 0 .. width)
            put(w, '^');
    else
        put(w, glyph);
    if (styled && color.length)
        put(w, sgrReset);
    put(w, '\n');
}

/// A message line indented to `col`.
private void writeIndented(Writer)(ref Writer w, size_t col, scope const(char)[] text,
    scope const(char)[] color, bool styled) @safe
{
    writeSpaces(w, col);
    if (styled && color.length)
        put(w, color);
    put(w, text);
    if (styled && color.length)
        put(w, sgrReset);
    put(w, '\n');
}

private void writeSpaces(Writer)(ref Writer w, size_t n) @safe
{
    foreach (_; 0 .. n)
        put(w, ' ');
}

/// In-place insertion sort + dedup of a small offset buffer.
private void sortUnique(ref SmallBuffer!size_t buf) @safe
{
    foreach (i; 1 .. buf.length)
    {
        const v = buf[i];
        size_t j = i;
        while (j > 0 && buf[j - 1] > v)
        {
            buf[j] = buf[j - 1];
            --j;
        }
        buf[j] = v;
    }
    // dedup in place
    size_t n = 0;
    foreach (i; 0 .. buf.length)
        if (n == 0 || buf[i] != buf[n - 1])
            buf[n++] = buf[i];
    while (buf.length > n)
        buf.popBack();
}

version (unittest)
{
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme, Theme;
    import sparkles.syntax.ts.registry : GrammarRegistry;

    private ResolvedTheme emptyTheme() @safe pure nothrow
        => resolveTheme(Theme(name: "t"), LabelSet.standard());

    private string renderTw(in TwoslashReturn tw, const(HighlightEvent)[] events,
        TwoslashAnsiOptions opts) @system
    {
        auto registry = GrammarRegistry.fromDirs([]); // no grammars → plain-text sigs
        auto cache = TsConfigCache.create(&registry, LabelSet.standard());
        SmallBuffer!(char, 1024) buf;
        renderTwoslashAnsi(tw, events, emptyTheme(), cache, buf, opts);
        return buf[].idup;
    }
}

@("render_ansi.queryBelowLine")
@system unittest
{
    // depth=none → plain output, so the meta structure is the whole golden.
    const tw = TwoslashReturn(code: "let b = 1\n", nodes: [
        Node(type: NodeType.query, start: 4, length: 1, line: 0, character: 4,
            text: "let b: number"),
    ]);
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.none)) ==
        "let b = 1\n" ~
        "    ^?\n" ~
        "    let b: number\n");
}

@("render_ansi.errorCaretAndMessage")
@system unittest
{
    const tw = TwoslashReturn(code: "x = y\n", nodes: [
        Node(type: NodeType.error, start: 4, length: 1, line: 0, character: 4,
            text: "no y", level: "error"),
    ]);
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.none)) ==
        "x = y\n" ~
        "    ^\n" ~
        "    no y\n");
}

@("render_ansi.tagLine")
@system unittest
{
    const tw = TwoslashReturn(code: "hi\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0,
            name: "log", text: "hello"),
    ]);
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.none)) ==
        "hi\n@log hello\n");
}

@("render_ansi.metaColorsFromPalette")
@system unittest
{
    import std.algorithm.searching : canFind;

    // At trueColor the brand chrome carries the single-source palette colors
    // (error #d45656, tag/info #3772cf) — the same values the CSS/GUI use.
    const err = TwoslashReturn(code: "x = y\n", nodes: [
        Node(type: NodeType.error, start: 4, length: 1, line: 0, character: 4,
            text: "no y", level: "error"),
    ]);
    const eOut = renderTw(err, null, TwoslashAnsiOptions(depth: ColorDepth.trueColor));
    assert(eOut.canFind("\x1b[38;2;212;86;86m")); // Slot.error fg
    assert(eOut.canFind("\x1b[0m"));

    const warn = TwoslashReturn(code: "x = y\n", nodes: [
        Node(type: NodeType.error, start: 4, length: 1, line: 0, character: 4,
            text: "meh", level: "warning"),
    ]);
    assert(renderTw(warn, null, TwoslashAnsiOptions(depth: ColorDepth.trueColor))
        .canFind("\x1b[38;2;195;125;13m")); // Slot.warn fg

    const tag = TwoslashReturn(code: "hi\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0,
            name: "log", text: "hello"),
    ]);
    assert(renderTw(tag, null, TwoslashAnsiOptions(depth: ColorDepth.trueColor))
        .canFind("\x1b[38;2;55;114;207m")); // Slot.info fg
}

@("render_ansi.trailingTagPastLastLine")
@system unittest
{
    // A trailing `@tag` (twoslash's shape for `// @annotate: …` at the very end)
    // anchors one line past the last code line — flush it below the code.
    const tw = TwoslashReturn(code: "hi\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 2, character: 0,
            name: "annotate", text: "trailing note"),
    ]);
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.none)) ==
        "hi\n@annotate trailing note\n");
}

@("render_ansi.completionList")
@system unittest
{
    const tw = TwoslashReturn(code: "a\n", nodes: [
        Node(type: NodeType.completion, start: 1, length: 0, line: 0, character: 1,
            completionsPrefix: "a", completions: [Completion("at"), Completion("apply")]),
    ]);
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.none)) ==
        "a\n" ~
        " ^\n" ~
        " - at\n" ~
        " - apply\n");
}

@("render_ansi.highlightReverseVideo")
@system unittest
{
    // With styling on, a highlight span is bracketed in reverse video. The
    // no-label code renders without its own SGR, so the golden is just the
    // reverse-video bracket around the text.
    const tw = TwoslashReturn(code: "abc", nodes: [
        Node(type: NodeType.highlight, start: 0, length: 3, line: 0, character: 0),
    ]);
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.ansi256)) ==
        "\x1b[7mabc\x1b[27m");
}

@("render_ansi.hoverSilentByDefault")
@system unittest
{
    const tw = TwoslashReturn(code: "a\n", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0, text: "T"),
    ]);
    // Default: hovers are silent — only the code line renders.
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.none)) == "a\n");
    // Opt-in: a ↳ line appears.
    assert(renderTw(tw, null, TwoslashAnsiOptions(depth: ColorDepth.none, hovers: true)) ==
        "a\n↳ T\n");
}
