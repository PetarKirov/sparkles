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
import sparkles.syntax.md.model : extractMarkdown, MdDoc;
import sparkles.syntax.md.render_html : renderMarkdownHtml, renderMarkdownInlineHtml;
import sparkles.syntax.render.html : renderHtml, HtmlMode, HtmlOptions;
import sparkles.syntax.theme : ResolvedTheme;
import sparkles.syntax.ts.injection : TsConfigCache;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.twoslash.icons : completionIconGlyph, completionIconSvg,
    tagIconGlyph, tagIconSvg;
import sparkles.twoslash.overlay : BelowBlock, InlineDecoration, highlightSignature,
    planTwoslash, TwoslashPlan, withoutQuickinfoPrefix;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;

/// How completion-kind icons are rendered before each candidate.
enum IconStyle
{
    svg,   /// the reference inline SVGs (default)
    glyph, /// a single Unicode glyph per kind
    none,  /// no icon span
}

/// Options for $(LREF renderTwoslashHtml).
struct TwoslashHtmlOptions
{
    /// Class prefix for the inner syntax spans (the `twoslash-*` chrome classes
    /// are fixed by the reference contract).
    const(char)[] classPrefix = "syn-";

    /// Strip a leading TS quickinfo kind prefix (`(property) `, `(parameter) `,
    /// …) from hover/query signatures. Off by default (keep it — it is
    /// informative). See $(REF withoutQuickinfoPrefix, sparkles,twoslash,overlay).
    bool stripQuickinfoPrefix = false;

    /// Which built-in completion-icon set to draw (default the reference SVGs).
    IconStyle completionIcons = IconStyle.svg;

    /// Optional per-kind icon override: given the completion `kind`, return the
    /// icon markup to emit inside the `twoslash-completions-icon` span. A
    /// non-empty return wins over `completionIcons`; an empty return (or a null
    /// delegate) falls back to the chosen style. `null` by default.
    const(char)[] delegate(scope const(char)[] kind) @safe customCompletionIcon = null;

    /// Which built-in custom-tag icon set to draw on `// @tag` lines
    /// (`@log`/`@error`/`@warn`/`@annotate`; default the reference SVGs).
    IconStyle tagIcons = IconStyle.svg;

    /// Render hover/query `docs` and `@tag` values as $(B markdown) (Shiki's
    /// `renderMarkdown`/`renderMarkdownInline` seam) via
    /// $(REF renderMarkdownHtml, sparkles,syntax,md,render_html). On by default;
    /// falls back to escaped text automatically when the markdown grammars are
    /// unavailable (so output degrades gracefully without a grammar bundle).
    bool renderDocsMarkdown = true;
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
                writePopup(w, theme, cache, tw.nodes[d.node], options);
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
            writeBelowBlock(w, theme, cache, tw.nodes[below[bi].node], options);
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
        writeBelowBlock(w, theme, cache, tw.nodes[below[bi].node], options);
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

/// The hover/query popup: `<span class="twoslash-popup-container"><div
/// class="twoslash-popup-arrow"></div><code class="twoslash-popup-code">{sig}</code>
/// [docs]</span>`. The connector arrow points the popup back at its token.
private void writePopup(Writer)(ref Writer w, in ResolvedTheme theme,
    ref TsConfigCache cache, in Node node, in TwoslashHtmlOptions options) @system
{
    put(w, `<span class="twoslash-popup-container"><div class="twoslash-popup-arrow"></div>`);
    put(w, `<code class="twoslash-popup-code">`);
    const text = options.stripQuickinfoPrefix ? withoutQuickinfoPrefix(node.text) : node.text;
    SmallBuffer!HighlightEvent sig;
    highlightSignature(cache, text, sig);
    renderHtml(text, sig[], theme, w, HtmlOptions(mode: HtmlMode.cssClasses));
    put(w, `</code>`);
    if (node.docs.length)
    {
        put(w, `<div class="twoslash-popup-docs">`);
        writeDocs(w, cache, node.docs, options, inline: false);
        put(w, `</div>`);
    }
    writePopupTags(w, cache, node, options);
    put(w, `</span>`);
}

/// Emits `md` into `w` as markdown (via the `sparkles:syntax` `MdDoc → HTML`
/// emitter) when `options.renderDocsMarkdown` and the markdown grammars parse it
/// to a non-empty document; otherwise (option off, or no grammar bundle) falls
/// back to escaped text, so docs never vanish. `inline` picks the paragraph-less
/// inline entry point (for a short tag value) over the block one (for `docs`).
private void writeDocs(Writer)(ref Writer w, ref TsConfigCache cache,
    scope const(char)[] md, in TwoslashHtmlOptions options, bool inline) @system
{
    if (options.renderDocsMarkdown)
    {
        MdDoc doc = extractMarkdown(cache.registry, md);
        if (doc.root.children.length) // grammars present and parse yielded blocks
        {
            if (inline)
                renderMarkdownInlineHtml(doc, w);
            else
                renderMarkdownHtml(doc, w);
            return;
        }
    }
    writeHtmlEscaped(w, md);
}

/// The JSDoc tags block: `<div class="twoslash-popup-docs twoslash-popup-docs-tags">`
/// with each tag as `@{name}` (a `-tag-name` span) plus its optional value span —
/// matching the `@shikijs/twoslash` structure. `text` is one opaque string (shiki
/// does not split `name - description`), rendered as inline markdown (Shiki's
/// `renderMarkdownInline`), degrading to escaped text without a grammar bundle.
private void writePopupTags(Writer)(ref Writer w, ref TsConfigCache cache,
    in Node node, in TwoslashHtmlOptions options) @system
{
    if (!node.tags.length)
        return;
    put(w, `<div class="twoslash-popup-docs twoslash-popup-docs-tags">`);
    foreach (ref const tag; node.tags)
    {
        if (!tag.length)
            continue;
        put(w, `<span class="twoslash-popup-docs-tag"><span class="twoslash-popup-docs-tag-name">@`);
        writeHtmlEscaped(w, tag[0]);
        put(w, `</span>`);
        if (tag.length > 1 && tag[1].length)
        {
            put(w, `<span class="twoslash-popup-docs-tag-value">`);
            writeDocs(w, cache, tag[1], options, inline: true);
            put(w, `</span>`);
        }
        put(w, `</span>`);
    }
    put(w, `</div>`);
}

/// A below-line block for a query / completion / error / tag node.
private void writeBelowBlock(Writer)(ref Writer w, in ResolvedTheme theme,
    ref TsConfigCache cache, in Node node, in TwoslashHtmlOptions options) @system
{
    final switch (node.type)
    {
        case NodeType.error:
            put(w, `<div class="twoslash-meta-line twoslash-error-line `);
            put(w, errorLevelClass(node.level));
            put(w, `">`);
            writeHtmlEscaped(w, node.text);
            put(w, `</div>`);
            break;

        case NodeType.query:
            // A single bare block element (like the completion `<ul>`), NOT a
            // popup-container span inside a wrapper div — the wrapper's line box
            // would inflate the top gap. `margin-left` sits it under the `^?`.
            put(w, `<div class="twoslash-meta-line twoslash-query-line"`);
            writeColumnOffset(w, node.character);
            put(w, `><div class="twoslash-popup-arrow"></div>`);
            put(w, `<code class="twoslash-popup-code">`);
            const text = options.stripQuickinfoPrefix ? withoutQuickinfoPrefix(node.text) : node.text;
            SmallBuffer!HighlightEvent sig;
            highlightSignature(cache, text, sig);
            renderHtml(text, sig[], theme, w, HtmlOptions(mode: HtmlMode.cssClasses));
            put(w, `</code></div>`);
            break;

        case NodeType.completion:
            writeCompletion(w, node, options);
            break;

        case NodeType.tag:
            put(w, `<div class="twoslash-tag-line twoslash-tag-`);
            foreach (char c; node.name)
                put(w, c);
            put(w, `-line">`);
            writeTagIcon(w, node.name, options);
            writeHtmlEscaped(w, node.text.length ? node.text : node.name);
            put(w, `</div>`);
            break;

        case NodeType.hover:
        case NodeType.highlight:
            break; // never below-line
    }
}

/// The completion list: `<ul class="twoslash-completion-list">`. Each `<li>` is
/// a per-kind icon span followed by a wrapper span holding the matched prefix +
/// unmatched remainder (the wrapper keeps the list's flex `gap` off the word, so
/// the candidate reads `parseFloat`, not `p arseFloat`) — matching the
/// `@shikijs/twoslash` structure.
private void writeCompletion(Writer)(ref Writer w, in Node node, in TwoslashHtmlOptions options)
{
    put(w, `<ul class="twoslash-completion-list"`);
    // Anchor under the START of the typed prefix (the caret column minus the
    // prefix already typed), i.e. where the completed identifier begins — e.g.
    // `Number.p|` anchors at column 7 (`Number.`), not the caret at 8.
    const col = node.character >= node.completionsPrefix.length
        ? node.character - node.completionsPrefix.length : 0;
    writeColumnOffset(w, col);
    put(w, `>`);
    // The connector arrow points at the completion CARET — `prefix.length`
    // columns right of the list's anchor (unlike the fixed-position arrow on
    // hover/query popups, which points near the token start).
    put(w, `<div class="twoslash-popup-arrow" style="left:`);
    writeUint(w, node.completionsPrefix.length);
    put(w, `ch"></div>`);
    foreach (ref const Completion c; node.completions)
    {
        put(w, `<li>`);
        writeCompletionIcon(w, c.kind, options);
        put(w, `<span>`);
        const pfx = node.completionsPrefix.length <= c.name.length
            && startsWith(c.name, node.completionsPrefix) ? node.completionsPrefix.length : 0;
        // Always emit both spans (matched empty when the name doesn't start with
        // the prefix), matching @shikijs/twoslash.
        put(w, `<span class="twoslash-completions-matched">`);
        writeHtmlEscaped(w, c.name[0 .. pfx]);
        put(w, `</span><span class="twoslash-completions-unmatched">`);
        writeHtmlEscaped(w, c.name[pfx .. $]);
        put(w, `</span></span></li>`);
    }
    put(w, `</ul>`);
}

/// Emits `<span class="twoslash-completions-icon completions-{kind}">{icon}</span>`
/// per the chosen style (custom override wins; `none` emits nothing).
private void writeCompletionIcon(Writer)(ref Writer w, scope const(char)[] kind,
    in TwoslashHtmlOptions options)
{
    const k = kind.length ? kind : "default";
    const(char)[] custom = options.customCompletionIcon is null
        ? null : options.customCompletionIcon(k);
    const(char)[] icon;
    if (custom.length)
        icon = custom;
    else final switch (options.completionIcons)
    {
        case IconStyle.svg:   icon = completionIconSvg(k);   break;
        case IconStyle.glyph: icon = completionIconGlyph(k); break;
        case IconStyle.none:  return; // no icon span at all
    }
    put(w, `<span class="twoslash-completions-icon completions-`);
    foreach (char ch; k) // shiki: whitespace in the kind → '-' for the class name
        put(w, (ch == ' ' || ch == '\t' || ch == '\n') ? '-' : ch);
    put(w, `">`);
    put(w, icon);
    put(w, `</span>`);
}

/// Emits `<span class="twoslash-tag-icon tag-{name}-icon">{icon}</span>` per the
/// chosen `tagIcons` style (`none` emits nothing), matching @shikijs/twoslash.
private void writeTagIcon(Writer)(ref Writer w, scope const(char)[] name,
    in TwoslashHtmlOptions options)
{
    const(char)[] icon;
    final switch (options.tagIcons)
    {
        case IconStyle.svg:   icon = tagIconSvg(name);   break;
        case IconStyle.glyph: icon = tagIconGlyph(name); break;
        case IconStyle.none:  return;
    }
    put(w, `<span class="twoslash-tag-icon tag-`);
    foreach (char ch; name)
        put(w, (ch == ' ' || ch == '\t' || ch == '\n') ? '-' : ch);
    put(w, `-icon">`);
    put(w, icon);
    put(w, `</span>`);
}

private bool startsWith(scope const(char)[] s, scope const(char)[] prefix)
    @safe pure nothrow @nogc
{
    if (prefix.length > s.length)
        return false;
    return s[0 .. prefix.length] == prefix;
}

/// Writes a decimal `size_t` (no allocation).
private void writeUint(Writer)(ref Writer w, size_t n)
{
    if (n >= 10)
        writeUint(w, n / 10);
    put(w, cast(char)('0' + cast(char)(n % 10)));
}

/// Emits ` style="margin-left:{character}ch"` (omitted at column 0) to shift a
/// below-line query/completion popup under its caret column. `ch` tracks the
/// monospace code grid so the popup and its arrow line up with the token above.
private void writeColumnOffset(Writer)(ref Writer w, size_t character)
{
    if (!character)
        return;
    put(w, ` style="margin-left:`);
    writeUint(w, character);
    put(w, `ch"`);
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
        `<div class="twoslash-popup-arrow"></div>` ~
        `<code class="twoslash-popup-code">const a: 1</code></span>a</span>`);
}

@("render_html.stripQuickinfoPrefix")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto registry = GrammarRegistry.fromDirs([]); // empty → plain-text popups
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());
    const tw = TwoslashReturn(code: "a", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0,
            text: "(property) title: string"),
    ]);

    // Default keeps the quickinfo prefix.
    SmallBuffer!(char, 512) keep;
    renderTwoslashHtml(tw, null, testTheme(), cache, keep);
    assert(canFind(keep[], "(property) title: string"));

    // Opt-in strips it.
    SmallBuffer!(char, 512) strip;
    renderTwoslashHtml(tw, null, testTheme(), cache, strip,
        TwoslashHtmlOptions(stripQuickinfoPrefix: true));
    assert(!canFind(strip[], "(property)"));
    assert(canFind(strip[], "title: string"));
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
        `<div class="twoslash-popup-arrow"></div>` ~
        `<code class="twoslash-popup-code">const a: 1</code>` ~
        `<div class="twoslash-popup-docs">the answer</div></span>a</span>`);
}

@("render_html.hoverPopupTags")
@system unittest
{
    // JSDoc tags render as `@name` chips after the docs; an empty value is
    // omitted; `text` is one opaque string (no name/description split).
    const tw = TwoslashReturn(code: "a", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0,
            text: "function ref(): void",
            tags: [["param", "value - the wrapped object"], ["returns", ""]]),
    ]);
    assert(renderTw(tw, null) ==
        `<span class="twoslash-hover"><span class="twoslash-popup-container">` ~
        `<div class="twoslash-popup-arrow"></div>` ~
        `<code class="twoslash-popup-code">function ref(): void</code>` ~
        `<div class="twoslash-popup-docs twoslash-popup-docs-tags">` ~
        `<span class="twoslash-popup-docs-tag">` ~
        `<span class="twoslash-popup-docs-tag-name">@param</span>` ~
        `<span class="twoslash-popup-docs-tag-value">value - the wrapped object</span></span>` ~
        `<span class="twoslash-popup-docs-tag">` ~
        `<span class="twoslash-popup-docs-tag-name">@returns</span></span>` ~
        `</div></span>a</span>`);
}

@("render_html.docsMarkdown")
@system unittest
{
    import std.process : environment;
    import std.algorithm.searching : canFind;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    // With the real markdown grammars, `docs` renders as markdown: a code span
    // becomes <code>, a tag value renders inline (no surrounding <p>).
    auto registry = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());
    const tw = TwoslashReturn(code: "a", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0,
            text: "const a: 1", docs: "the `answer` value",
            tags: [["param", "the wrapped `obj`"]]),
    ]);
    SmallBuffer!(char, 2048) buf;
    renderTwoslashHtml(tw, null, testTheme(), cache, buf);

    // docs: block markdown → wrapped in a <p>, code span highlighted.
    assert(canFind(buf[],
        `<div class="twoslash-popup-docs"><p>the <code>answer</code> value</p></div>`));
    // tag value: inline markdown → NO <p>, code span present.
    assert(canFind(buf[],
        `<span class="twoslash-popup-docs-tag-value">the wrapped <code>obj</code></span>`));

    // Opt-out restores escaped text (no <code>/<p>).
    SmallBuffer!(char, 2048) plain;
    renderTwoslashHtml(tw, null, testTheme(), cache, plain,
        TwoslashHtmlOptions(renderDocsMarkdown: false));
    assert(canFind(plain[], `<div class="twoslash-popup-docs">the `~"`answer`"~` value</div>`));
    assert(!canFind(plain[], "<code>"));
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
        `<div class="twoslash-meta-line twoslash-error-line twoslash-error-level-error">no y</div>`);
}

@("render_html.tagBelowLine")
@system unittest
{
    const tw = TwoslashReturn(code: "hi\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0,
            name: "log", text: "hello"),
    ]);
    // Icons off → golden is just the tag line.
    auto registry = GrammarRegistry.fromDirs([]);
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());
    SmallBuffer!(char, 512) buf;
    renderTwoslashHtml(tw, null, testTheme(), cache, buf,
        TwoslashHtmlOptions(tagIcons: IconStyle.none));
    assert(buf[] ==
        "hi\n" ~
        `<div class="twoslash-tag-line twoslash-tag-log-line">hello</div>`);
}

@("render_html.tagIcon")
@system unittest
{
    import std.algorithm.searching : canFind;

    const tw = TwoslashReturn(code: "hi\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0,
            name: "annotate", text: "note"),
    ]);
    // Default (svg): a per-name tag-icon span with an inline <svg>.
    assert(canFind(renderTw(tw, null),
        `twoslash-tag-annotate-line"><span class="twoslash-tag-icon tag-annotate-icon"><svg`));

    auto registry = GrammarRegistry.fromDirs([]);
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());
    SmallBuffer!(char, 512) g;
    renderTwoslashHtml(tw, null, testTheme(), cache, g,
        TwoslashHtmlOptions(tagIcons: IconStyle.glyph));
    assert(canFind(g[], `<span class="twoslash-tag-icon tag-annotate-icon">✎</span>`));
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
    // Icons off → the golden isolates the trailing-flush behaviour.
    auto registry = GrammarRegistry.fromDirs([]);
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());
    SmallBuffer!(char, 512) buf;
    renderTwoslashHtml(tw, null, testTheme(), cache, buf,
        TwoslashHtmlOptions(tagIcons: IconStyle.none));
    assert(buf[] ==
        "a\n" ~
        `<div class="twoslash-tag-line twoslash-tag-annotate-line">trailing note</div>`);
}

@("render_html.completionList")
@system unittest
{
    // character 8, prefix "a" (len 1) → the list anchors at column 8 − 1 = 7,
    // under the start of the typed identifier.
    const tw = TwoslashReturn(code: "a\n", nodes: [
        Node(type: NodeType.completion, start: 8, length: 0, line: 0, character: 8,
            completionsPrefix: "a", completions: [Completion("at", "method"),
                Completion("apply", "method")]),
    ]);
    // Icons off → the golden is just the matched/unmatched wrapper structure. The
    // inner `<span>` wrapping matched+unmatched is what keeps the list's flex gap
    // off the word.
    auto registry = GrammarRegistry.fromDirs([]);
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());
    SmallBuffer!(char, 1024) buf;
    renderTwoslashHtml(tw, null, testTheme(), cache, buf,
        TwoslashHtmlOptions(completionIcons: IconStyle.none));
    assert(buf[] ==
        "a\n" ~
        `<ul class="twoslash-completion-list" style="margin-left:7ch">` ~
        `<div class="twoslash-popup-arrow" style="left:1ch"></div>` ~
        `<li><span><span class="twoslash-completions-matched">a</span>` ~
        `<span class="twoslash-completions-unmatched">t</span></span></li>` ~
        `<li><span><span class="twoslash-completions-matched">a</span>` ~
        `<span class="twoslash-completions-unmatched">pply</span></span></li>` ~
        `</ul>`);
}

@("render_html.completionIcons")
@system unittest
{
    import std.algorithm.searching : canFind;

    const tw = TwoslashReturn(code: "a\n", nodes: [
        Node(type: NodeType.completion, start: 1, length: 0, line: 0, character: 1,
            completionsPrefix: "a", completions: [Completion("apply", "method")]),
    ]);
    // Default (svg): the per-kind class + an inline <svg> icon.
    assert(canFind(renderTw(tw, null),
        `<li><span class="twoslash-completions-icon completions-method"><svg`));

    auto registry = GrammarRegistry.fromDirs([]);
    auto cache = TsConfigCache.create(&registry, LabelSet.standard());
    // Glyph style: same class, a text glyph.
    SmallBuffer!(char, 512) g;
    renderTwoslashHtml(tw, null, testTheme(), cache, g,
        TwoslashHtmlOptions(completionIcons: IconStyle.glyph));
    assert(canFind(g[], `<span class="twoslash-completions-icon completions-method">ƒ</span>`));

    // Custom override wins over the style.
    SmallBuffer!(char, 512) cu;
    renderTwoslashHtml(tw, null, testTheme(), cache, cu,
        TwoslashHtmlOptions(customCompletionIcon: (scope const(char)[] k) => "★"));
    assert(canFind(cu[], `<span class="twoslash-completions-icon completions-method">★</span>`));
}

@("render_html.popupArrowAndOffset")
@system unittest
{
    import std.algorithm.searching : canFind;

    // Both the hover and the query popup carry the connector arrow; the below-line
    // query popup is offset under its caret column via `margin-left`.
    const tw = TwoslashReturn(code: "ab\n", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0, text: "T"),
        Node(type: NodeType.query, start: 1, length: 1, line: 0, character: 1, text: "b: number"),
    ]);
    const html = renderTw(tw, null);
    // Hover popup carries the arrow.
    assert(canFind(html,
        `twoslash-hover"><span class="twoslash-popup-container">` ~
        `<div class="twoslash-popup-arrow"></div><code`));
    // Query popup carries the arrow AND is offset under its caret column. It is a
    // single bare block element (no popup-container wrapper span).
    assert(canFind(html,
        `twoslash-query-line" style="margin-left:1ch">` ~
        `<div class="twoslash-popup-arrow"></div><code`));
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
