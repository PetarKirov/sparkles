/**
The HTML twoslash overlay: folds a highlighted snippet plus its twoslash nodes
into the reference `@shikijs/twoslash` $(D .twoslash-*) class contract, so the
existing `style-rich.css` (ported in $(MREF sparkles,twoslash,style)) styles it
with zero JS — interactivity is pure CSS `:hover`.

$(B Approach.) `sparkles:syntax`'s $(REF renderHtml, sparkles,syntax,render,html)
emits `<span class="syn-…">` from labels only; it cannot produce the twoslash
wrapper markup. So this renderer owns its main loop but reuses the pieces:
$(REF byStyledSpan, sparkles,syntax,event) for flat single-label syntax runs,
the theme's dotted→dashed class names, `writeHtmlEscaped`, and — crucially —
`renderHtml` itself, called $(B reentrantly) to re-highlight each hover/query
type signature inside its popup (Shiki does exactly this).

$(B Nesting model.) `byStyledSpan` already flattens syntax to non-overlapping
single-label runs, so syntax spans never nest each other — only twoslash
decorations nest (outer-first, guaranteed by
$(REF planTwoslash, sparkles,twoslash,overlay)). And inline decorations are
line-scoped (a hover/highlight/error covers a token on one line), so no
decoration ever crosses a `'\n'`. A sweep over the union of {run edges,
decoration edges, newlines} therefore needs only: a decoration stack (outer),
one syntax `<span>` per segment (inner), and the close/reopen-at-`'\n'`
discipline — with below-line blocks flushed at each newline seam (after the
tags close, before the next line) so every output line stays valid markup.

`@system` (reentrant highlight) and not `@nogc` (it allocates).
*/
module sparkles.twoslash.render_html;

import std.array : array;
import std.range.primitives : put;

import sparkles.base.text.html : writeHtmlEscaped;

import sparkles.syntax.event : HighlightEvent, LabelId, StyledSpan, byStyledSpan;
import sparkles.syntax.render.html : renderHtml, HtmlMode, HtmlOptions;
import sparkles.syntax.theme : ResolvedTheme;
import sparkles.syntax.ts.injection : TsConfigCache;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.twoslash.overlay : BelowBlock, InlineDecoration, highlightSignature,
    planTwoslash, TwoslashPlan;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;

/// Options for $(LREF renderTwoslashHtml).
struct TwoslashHtmlOptions
{
    /// Class prefix for the inner syntax spans (the `twoslash-*` chrome classes
    /// are fixed by the reference contract).
    const(char)[] classPrefix = "syn-";
}

/**
Renders `tw` (its `code` already highlighted into `events`) as the twoslash
HTML overlay into `w`. `cache` drives the reentrant popup re-highlighting.

Output is $(B content only) — no `pre`/`code`/`.twoslash` wrapper; the caller
wraps it (pair with the ported stylesheet's `.twoslash` container +
$(REF writeThemeStylesheet, sparkles,syntax,render,html)'s `.syn-root`).
*/
ref Writer renderTwoslashHtml(Writer)(
    in TwoslashReturn tw,
    scope const(HighlightEvent)[] events,
    in ResolvedTheme theme,
    ref TsConfigCache cache,
    return ref Writer w,
    in TwoslashHtmlOptions options = TwoslashHtmlOptions(),
) @system
{
    const code = tw.code;
    auto plan = planTwoslash(tw);
    auto runs = byStyledSpan(events).array; // flat, non-overlapping single-label runs

    const inlineDecos = plan.inlineDecorations; // sorted: start asc, end desc
    const below = plan.belowBlocks;             // sorted by line

    SmallBuffer!(InlineDecoration, 8) openDecos;
    size_t di = 0;      // next decoration to open
    size_t si = 0;      // syntax run cursor
    size_t bi = 0;      // next below-block to flush
    size_t line = 0;    // current 0-based line
    size_t pos = 0;

    // The innermost syntax label covering `off` (advancing the run cursor).
    LabelId labelAt(size_t off)
    {
        while (si < runs.length && runs[si].end <= off)
            ++si;
        if (si < runs.length && off >= runs[si].start && off < runs[si].end)
            return runs[si].label;
        return LabelId.none;
    }

    // Opening / closing tags for a decoration (the popup markup lives on open).
    void openDeco(in InlineDecoration d)
    {
        final switch (d.kind)
        {
            case NodeType.hover:
                put(w, `<span class="twoslash-hover">`);
                writePopup(w, theme, cache, tw.nodes[d.node]);
                break;
            case NodeType.highlight:
                put(w, `<span class="twoslash-highlighted">`);
                break;
            case NodeType.error:
                put(w, `<span class="twoslash-error `);
                put(w, errorLevelClass(tw.nodes[d.node].level));
                put(w, `">`);
                break;
            case NodeType.query:
            case NodeType.completion:
            case NodeType.tag:
                break; // never inline
        }
    }

    void closeDeco()
    {
        put(w, "</span>");
    }

    // Flush all below-line blocks anchored to `flushedLine`, at the newline seam
    // (all spans closed → the block <div>s are valid top-level markup).
    void flushBelow(size_t flushedLine)
    {
        while (bi < below.length && below[bi].line == flushedLine)
        {
            writeBelowBlock(w, theme, cache, tw.nodes[below[bi].node]);
            ++bi;
        }
    }

    while (pos < code.length)
    {
        // Close decorations ending here (innermost first).
        while (openDecos.length && openDecos[openDecos.length - 1].end == pos)
        {
            closeDeco();
            openDecos.popBack();
        }
        // Open decorations starting here (outer-first per the plan's sort).
        while (di < inlineDecos.length && inlineDecos[di].start == pos)
        {
            openDeco(inlineDecos[di]);
            openDecos ~= inlineDecos[di];
            ++di;
        }

        // Newline: close the (empty — decos are line-scoped) stack defensively,
        // emit '\n', flush this line's below-blocks, advance.
        if (code[pos] == '\n')
        {
            foreach_reverse (_; 0 .. openDecos.length)
                closeDeco();
            put(w, '\n');
            flushBelow(line);
            ++line;
            // Reopen any decoration that (defensively) spanned the newline.
            foreach (i; 0 .. openDecos.length)
                openDeco(openDecos[i]);
            ++pos;
            continue;
        }

        // Segment end = next structural boundary or newline.
        size_t next = code.length;
        if (di < inlineDecos.length && inlineDecos[di].start > pos)
            next = min(next, inlineDecos[di].start);
        if (openDecos.length)
            next = min(next, openDecos[openDecos.length - 1].end);
        const lbl = labelAt(pos);
        if (si < runs.length)
            next = pos < runs[si].start ? min(next, runs[si].start) : min(next, runs[si].end);
        next = nextNewlineBounded(code, pos, next);

        // Emit the segment wrapped in its single syntax span.
        const emitted = writeSyntaxOpen(w, theme, lbl, options.classPrefix);
        writeHtmlEscaped(w, code[pos .. next]);
        if (emitted)
            put(w, "</span>");
        pos = next;
    }

    // Close anything still open, then flush the final line's blocks plus any
    // trailing ones anchored past the last line — twoslash gives a trailing
    // `@tag`/query a line index one past the end (`below` is sorted, so the
    // remainder is exactly those trailing blocks).
    foreach_reverse (_; 0 .. openDecos.length)
        closeDeco();
    while (bi < below.length)
    {
        writeBelowBlock(w, theme, cache, tw.nodes[below[bi].node]);
        ++bi;
    }
    return w;
}

private size_t min(size_t a, size_t b) @safe pure nothrow @nogc => a < b ? a : b;

/// The first `'\n'` in `code[pos .. cap]`, or `cap` if none — so a segment never
/// straddles a line break.
private size_t nextNewlineBounded(scope const(char)[] code, size_t pos, size_t cap)
    @safe pure nothrow @nogc
{
    foreach (i; pos .. cap)
        if (code[i] == '\n')
            return i;
    return cap;
}

/// The `twoslash-error-level-*` modifier class for an error `level`
/// (`""`/`"error"` → error; others map by name).
private const(char)[] errorLevelClass(scope const(char)[] level) @safe pure nothrow @nogc
{
    switch (level)
    {
        case "warning": return "twoslash-error-level-warning";
        case "suggestion": return "twoslash-error-level-suggestion";
        case "message": return "twoslash-error-level-message";
        default: return "twoslash-error-level-error";
    }
}

/// Opens a `<span class="<prefix><name>">` for a real syntax label; returns
/// whether a tag was written (so the caller mirrors the close).
private bool writeSyntaxOpen(Writer)(ref Writer w, in ResolvedTheme theme, LabelId label,
    scope const(char)[] classPrefix)
{
    if (!label || label.value >= theme.labels.length)
        return false;
    put(w, `<span class="`);
    put(w, classPrefix);
    foreach (char c; theme.labels.name(label))
        put(w, c == '.' ? '-' : c);
    put(w, `">`);
    return true;
}

/// The hover/query popup: `<span class="twoslash-popup-container"><code
/// class="twoslash-popup-code">{re-highlighted sig}</code>[docs]</span>`.
private void writePopup(Writer)(ref Writer w, in ResolvedTheme theme,
    ref TsConfigCache cache, in Node node) @system
{
    put(w, `<span class="twoslash-popup-container"><code class="twoslash-popup-code">`);
    SmallBuffer!HighlightEvent sig;
    highlightSignature(cache, node.text, sig);
    renderHtml(node.text, sig[], theme, w, HtmlOptions(mode: HtmlMode.cssClasses));
    put(w, `</code>`);
    if (node.docs.length)
    {
        put(w, `<div class="twoslash-popup-docs">`);
        writeHtmlEscaped(w, node.docs);
        put(w, `</div>`);
    }
    put(w, `</span>`);
}

/// A below-line block for a query / completion / error / tag node.
private void writeBelowBlock(Writer)(ref Writer w, in ResolvedTheme theme,
    ref TsConfigCache cache, in Node node) @system
{
    final switch (node.type)
    {
        case NodeType.error:
            put(w, `<div class="twoslash-error-line `);
            put(w, errorLevelClass(node.level));
            put(w, `">`);
            writeHtmlEscaped(w, node.text);
            put(w, `</div>`);
            break;

        case NodeType.query:
            put(w, `<div class="twoslash-meta-line twoslash-query-line">`);
            put(w, `<span class="twoslash-popup-container"><code class="twoslash-popup-code">`);
            SmallBuffer!HighlightEvent sig;
            highlightSignature(cache, node.text, sig);
            renderHtml(node.text, sig[], theme, w, HtmlOptions(mode: HtmlMode.cssClasses));
            put(w, `</code></span></div>`);
            break;

        case NodeType.completion:
            writeCompletion(w, node);
            break;

        case NodeType.tag:
            put(w, `<div class="twoslash-tag-line twoslash-tag-`);
            foreach (char c; node.name)
                put(w, c);
            put(w, `-line">`);
            writeHtmlEscaped(w, node.text.length ? node.text : node.name);
            put(w, `</div>`);
            break;

        case NodeType.hover:
        case NodeType.highlight:
            break; // never below-line
    }
}

/// The completion list: `<ul class="twoslash-completion-list">` with each
/// candidate split into its matched prefix and unmatched remainder.
private void writeCompletion(Writer)(ref Writer w, in Node node)
{
    put(w, `<ul class="twoslash-completion-list">`);
    foreach (ref const Completion c; node.completions)
    {
        put(w, `<li>`);
        const pfx = node.completionsPrefix.length <= c.name.length
            && startsWith(c.name, node.completionsPrefix) ? node.completionsPrefix.length : 0;
        if (pfx)
        {
            put(w, `<span class="twoslash-completions-matched">`);
            writeHtmlEscaped(w, c.name[0 .. pfx]);
            put(w, `</span>`);
        }
        put(w, `<span class="twoslash-completions-unmatched">`);
        writeHtmlEscaped(w, c.name[pfx .. $]);
        put(w, `</span></li>`);
    }
    put(w, `</ul>`);
}

private bool startsWith(scope const(char)[] s, scope const(char)[] prefix)
    @safe pure nothrow @nogc
{
    if (prefix.length > s.length)
        return false;
    return s[0 .. prefix.length] == prefix;
}

version (unittest)
{
    import sparkles.syntax.event : LabelId;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : Theme, ThemeRule, StyleSpec, resolveTheme;
    import sparkles.syntax.color : Color;
    import sparkles.syntax.ts.registry : GrammarRegistry;

    // A theme carrying the standard label vocabulary so `syn-*` class names
    // resolve; an EMPTY grammar registry so the reentrant popup highlight always
    // degrades to plain text — goldens stay deterministic regardless of whether
    // $SPARKLES_TS_GRAMMAR_PATH is set.
    private ResolvedTheme testTheme() @safe pure nothrow
    {
        const t = Theme(name: "t", rules: [
            ThemeRule("keyword", StyleSpec(fg: Color.fromRgb(0xcb, 0xa6, 0xf7))),
        ]);
        return resolveTheme(t, LabelSet.standard());
    }

    private LabelId kw() @safe pure nothrow
    {
        const id = LabelSet.standard().find("keyword");
        assert(id);
        return id;
    }

    // Renders `tw` (+ its syntax events) with an empty cache into a fresh buffer.
    private string renderTw(in TwoslashReturn tw, const(HighlightEvent)[] events) @system
    {
        auto registry = GrammarRegistry.fromDirs([]); // no grammars → plain-text popups
        auto cache = TsConfigCache.create(&registry, LabelSet.standard());
        SmallBuffer!(char, 1024) buf;
        renderTwoslashHtml(tw, events, testTheme(), cache, buf);
        return buf[].idup;
    }
}

@("render_html.highlight")
@system unittest
{
    const tw = TwoslashReturn(code: "abc", nodes: [
        Node(type: NodeType.highlight, start: 0, length: 3, line: 0, character: 0),
    ]);
    assert(renderTw(tw, null) == `<span class="twoslash-highlighted">abc</span>`);
}

@("render_html.decorationWrapsSyntax")
@system unittest
{
    import sparkles.syntax.event : HighlightEvent;

    // "let x": keyword over "let", a highlight over the same range. The
    // decoration must be OUTER, the syntax span INNER.
    const tw = TwoslashReturn(code: "let x", nodes: [
        Node(type: NodeType.highlight, start: 0, length: 3, line: 0, character: 0),
    ]);
    const events = [
        HighlightEvent.pushLabel(kw()), HighlightEvent.sourceSpan(0, 3),
        HighlightEvent.popLabel(), HighlightEvent.sourceSpan(3, 5),
    ];
    assert(renderTw(tw, events) ==
        `<span class="twoslash-highlighted"><span class="syn-keyword">let</span></span> x`);
}

@("render_html.hoverPopup")
@system unittest
{
    const tw = TwoslashReturn(code: "a", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0,
            text: "const a: 1"),
    ]);
    assert(renderTw(tw, null) ==
        `<span class="twoslash-hover"><span class="twoslash-popup-container">` ~
        `<code class="twoslash-popup-code">const a: 1</code></span>a</span>`);
}

@("render_html.hoverPopupWithDocs")
@system unittest
{
    const tw = TwoslashReturn(code: "a", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0,
            text: "const a: 1", docs: "the answer"),
    ]);
    assert(renderTw(tw, null) ==
        `<span class="twoslash-hover"><span class="twoslash-popup-container">` ~
        `<code class="twoslash-popup-code">const a: 1</code>` ~
        `<div class="twoslash-popup-docs">the answer</div></span>a</span>`);
}

@("render_html.errorInlineAndBelow")
@system unittest
{
    import sparkles.syntax.event : HighlightEvent;

    // "x = y\n": an error over "y" on line 0 → inline wavy span + below message.
    const tw = TwoslashReturn(code: "x = y\n", nodes: [
        Node(type: NodeType.error, start: 4, length: 1, line: 0, character: 4,
            text: "no y", level: "error"),
    ]);
    assert(renderTw(tw, null) ==
        `x = <span class="twoslash-error twoslash-error-level-error">y</span>` ~
        "\n" ~
        `<div class="twoslash-error-line twoslash-error-level-error">no y</div>`);
}

@("render_html.tagBelowLine")
@system unittest
{
    const tw = TwoslashReturn(code: "hi\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0,
            name: "log", text: "hello"),
    ]);
    assert(renderTw(tw, null) ==
        "hi\n" ~
        `<div class="twoslash-tag-line twoslash-tag-log-line">hello</div>`);
}

@("render_html.trailingTagPastLastLine")
@system unittest
{
    // A trailing `@tag` (as twoslash emits for `// @annotate: …` at the very end)
    // anchors one line past the code's last line — it must still be flushed.
    const tw = TwoslashReturn(code: "a\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 2, character: 0,
            name: "annotate", text: "trailing note"),
    ]);
    assert(renderTw(tw, null) ==
        "a\n" ~
        `<div class="twoslash-tag-line twoslash-tag-annotate-line">trailing note</div>`);
}

@("render_html.completionList")
@system unittest
{
    const tw = TwoslashReturn(code: "a\n", nodes: [
        Node(type: NodeType.completion, start: 1, length: 0, line: 0, character: 1,
            completionsPrefix: "a", completions: [Completion("at", "method"),
                Completion("apply", "method")]),
    ]);
    assert(renderTw(tw, null) ==
        "a\n" ~
        `<ul class="twoslash-completion-list">` ~
        `<li><span class="twoslash-completions-matched">a</span>` ~
        `<span class="twoslash-completions-unmatched">t</span></li>` ~
        `<li><span class="twoslash-completions-matched">a</span>` ~
        `<span class="twoslash-completions-unmatched">pply</span></li>` ~
        `</ul>`);
}

@("render_html.escaping")
@system unittest
{
    const tw = TwoslashReturn(code: `a<b`, nodes: []);
    assert(renderTw(tw, null) == "a&lt;b");
}

@("render_html.perLineValidity")
@system unittest
{
    // Every output line must have balanced <span>/<div> open/close tags — the
    // machine-checked invariant (mirrors render/html.d's own scan).
    const tw = TwoslashReturn(code: "a = b\nc = d\n", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0, text: "T"),
        Node(type: NodeType.error, start: 8, length: 1, line: 1, character: 2,
            text: "err", level: "error"),
        Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0, name: "x"),
    ]);
    const html = renderTw(tw, null);
    size_t open, close;
    foreach (i; 0 .. html.length)
    {
        const c = html[i];
        if (c == '\n')
        {
            assert(open == close, "unbalanced tags on a line");
            open = close = 0;
        }
        else if (c == '<' && i + 1 < html.length)
            (html[i + 1] == '/') ? ++close : ++open;
    }
    assert(open == close, "unbalanced tags on the last line");
}
