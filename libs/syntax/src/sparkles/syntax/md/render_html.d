/**
An HTML backend for the structural markdown model ($(MREF sparkles,syntax,md,model)).

Walks an $(REF MdDoc, sparkles,syntax,md,model) — the block/inline tree
`extractMarkdown` yields — and emits standard HTML. It is the render-side sibling
of `hue --gui`'s `PreviewLine` presentation: same model, a different surface (HTML
instead of a raylib grid). The seam mirrors Shiki's `renderMarkdown` /
`renderMarkdownInline` pair used by `@shikijs/twoslash` to turn JSDoc `docs` and
`@tag` values into markup:

$(UL
    $(LI $(LREF renderMarkdownHtml) — $(B block) level: the document's blocks as
        `<p>`/`<h1>`/`<ul>`/`<pre>`/… — for a hover/query `docs` string.)
    $(LI $(LREF renderMarkdownInlineHtml) — $(B inline) level: a single paragraph
        rendered $(B without) its `<p>` wrapper (multi-block input falls back to
        the block form) — for a short `@param foo the `code`` tag value.)
)

$(B Scope.) Structure and inline styling only. Fenced code is emitted as an
escaped `<pre><code class="language-…">` block — this module deliberately does
$(B not) re-highlight it (that would couple it to a grammar registry); a caller
wanting highlighted doc-code can post-process the fence. Raw `htmlBlock`s pass
through verbatim (standard markdown semantics — the doc author's HTML). Everything
else is escaped via $(REF writeHtmlEscaped, sparkles,base,text,html).

Totality: never fails on any `MdDoc`; an empty document emits nothing.
*/
module sparkles.syntax.md.render_html;

import std.range.primitives : put;

import sparkles.base.text.html : writeHtmlEscaped;

import sparkles.syntax.md.model : MdBlock, MdBlockKind, MdDoc, MdInline,
    MdInlineKind, Span;

/// Options for $(LREF renderMarkdownHtml) / $(LREF renderMarkdownInlineHtml).
struct MarkdownHtmlOptions
{
    /// Class-name prefix for a fenced-code language (`language-d`, …). The
    /// GitHub/markdown-it convention; set empty to drop the class entirely.
    const(char)[] codeLanguagePrefix = "language-";
}

/**
Renders `doc` as $(B block-level) HTML content into `w` (no wrapping element —
the caller supplies any container). Returns `w`.

`w` is any `char` output range; attributes infer (a `@nogc` writer keeps the
whole walk `@nogc`).
*/
ref Writer renderMarkdownHtml(Writer)(
    in MdDoc doc,
    return ref Writer w,
    in MarkdownHtmlOptions options = MarkdownHtmlOptions(),
)
{
    foreach (ref const b; doc.root.children)
        writeBlock(w, doc.source, b, options);
    return w;
}

/**
Renders `doc` as $(B inline) HTML into `w`. When the document is a single
paragraph its inlines are emitted $(B without) the surrounding `<p>` (the common
case for a one-line JSDoc tag value); anything richer — multiple blocks, a
heading, a list — falls back to $(LREF renderMarkdownHtml). Returns `w`.
*/
ref Writer renderMarkdownInlineHtml(Writer)(
    in MdDoc doc,
    return ref Writer w,
    in MarkdownHtmlOptions options = MarkdownHtmlOptions(),
)
{
    const blocks = doc.root.children;
    if (blocks.length == 1 && blocks[0].kind == MdBlockKind.paragraph)
        writeInlines(w, doc.source, blocks[0].inlines);
    else
        renderMarkdownHtml(doc, w, options);
    return w;
}

// ─────────────────────────────────────────────────────────────────────────────

private void writeBlock(Writer)(ref Writer w, scope const(char)[] src,
    in MdBlock b, in MarkdownHtmlOptions options)
{
    final switch (b.kind)
    {
        case MdBlockKind.document:
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options);
            break;

        case MdBlockKind.heading:
            const tag = headingTag(b.level);
            put(w, "<"); put(w, tag); put(w, ">");
            writeInlines(w, src, b.inlines);
            put(w, "</"); put(w, tag); put(w, ">");
            break;

        case MdBlockKind.paragraph:
            put(w, "<p>");
            writeInlines(w, src, b.inlines);
            put(w, "</p>");
            break;

        case MdBlockKind.codeFence:
            put(w, "<pre><code");
            if (b.infoLang.length && options.codeLanguagePrefix.length)
            {
                put(w, ` class="`);
                put(w, options.codeLanguagePrefix);
                foreach (char c; b.infoLang)
                    put(w, c == '.' ? '-' : c);
                put(w, `"`);
            }
            put(w, ">");
            if (b.codeBody.end > b.codeBody.start)
                writeHtmlEscaped(w, slice(src, b.codeBody));
            put(w, "</code></pre>");
            break;

        case MdBlockKind.blockQuote:
            put(w, "<blockquote>");
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options);
            put(w, "</blockquote>");
            break;

        case MdBlockKind.list:
            const tag = b.ordered ? "ol" : "ul";
            put(w, "<"); put(w, tag); put(w, ">");
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options);
            put(w, "</"); put(w, tag); put(w, ">");
            break;

        case MdBlockKind.listItem:
            put(w, "<li>");
            if (b.checkbox >= 0) // a task-list item: a disabled checkbox marker
            {
                put(w, b.checkbox == 1
                    ? `<input type="checkbox" disabled checked> `
                    : `<input type="checkbox" disabled> `);
            }
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options);
            put(w, "</li>");
            break;

        case MdBlockKind.thematicBreak:
            put(w, "<hr>");
            break;

        case MdBlockKind.table:
            writeTable(w, src, b);
            break;

        case MdBlockKind.tableRow:  // only reached via writeTable
        case MdBlockKind.tableCell:
            break;

        case MdBlockKind.htmlBlock:
            put(w, slice(src, b.span)); // raw HTML passthrough (markdown semantics)
            break;
    }
}

// The first row of a `table` is the header (`<th>` in a `<thead>`); the rest are
// `<td>` body rows.
private void writeTable(Writer)(ref Writer w, scope const(char)[] src, in MdBlock t)
{
    put(w, "<table>");
    foreach (i, ref const row; t.children)
    {
        const header = i == 0;
        if (header)
            put(w, "<thead><tr>");
        else if (i == 1)
            put(w, "<tbody><tr>");
        else
            put(w, "<tr>");
        const cellTag = header ? "th" : "td";
        foreach (ref const cell; row.children)
        {
            put(w, "<"); put(w, cellTag); put(w, ">");
            writeInlines(w, src, cell.inlines);
            put(w, "</"); put(w, cellTag); put(w, ">");
        }
        put(w, "</tr>");
        if (header)
            put(w, "</thead>");
    }
    if (t.children.length > 1)
        put(w, "</tbody>");
    put(w, "</table>");
}

private void writeInlines(Writer)(ref Writer w, scope const(char)[] src,
    in MdInline[] inlines)
{
    foreach (ref const inl; inlines)
        writeInline(w, src, inl);
}

private void writeInline(Writer)(ref Writer w, scope const(char)[] src, in MdInline inl)
{
    final switch (inl.kind)
    {
        case MdInlineKind.text:
            writeHtmlEscaped(w, slice(src, inl.span));
            break;

        case MdInlineKind.emphasis:
            put(w, "<em>");
            writeInlines(w, src, inl.children);
            put(w, "</em>");
            break;

        case MdInlineKind.strong:
            put(w, "<strong>");
            writeInlines(w, src, inl.children);
            put(w, "</strong>");
            break;

        case MdInlineKind.strikethrough:
            put(w, "<del>");
            writeInlines(w, src, inl.children);
            put(w, "</del>");
            break;

        case MdInlineKind.codeSpan:
            put(w, "<code>");
            writeHtmlEscaped(w, slice(src, inl.span));
            put(w, "</code>");
            break;

        case MdInlineKind.link:
            put(w, `<a href="`);
            writeHtmlEscaped(w, inl.linkDest);
            put(w, `">`);
            writeInlines(w, src, inl.children);
            put(w, "</a>");
            break;

        case MdInlineKind.image:
            put(w, `<img src="`);
            writeHtmlEscaped(w, inl.linkDest);
            put(w, `" alt="`);
            foreach (ref const c; inl.children) // alt = concatenated leaf text
                if (c.kind == MdInlineKind.text)
                    writeHtmlEscaped(w, slice(src, c.span));
            put(w, `">`);
            break;

        case MdInlineKind.lineBreak:
            put(w, "<br>");
            break;
    }
}

private const(char)[] slice(return scope const(char)[] src, in Span s) @safe pure nothrow @nogc
    => s.end <= src.length && s.start <= s.end ? src[s.start .. s.end] : null;

// h1..h6, clamped.
private string headingTag(ubyte level) @safe pure nothrow @nogc
{
    switch (level)
    {
        case 1: return "h1";
        case 2: return "h2";
        case 3: return "h3";
        case 4: return "h4";
        case 5: return "h5";
        default: return "h6";
    }
}

// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.process : environment;
    import sparkles.syntax.md.model : extractMarkdown;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    // Render `md` to a block-HTML string (grammar-bundle gated).
    private string renderBlock(string md) @system
    {
        import std.array : appender;
        if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
        auto registry = GrammarRegistry.fromEnvironment();
        auto doc = extractMarkdown(registry, md);
        auto buf = appender!string;
        renderMarkdownHtml(doc, buf);
        return buf[];
    }

    private string renderInline(string md) @system
    {
        import std.array : appender;
        if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
        auto registry = GrammarRegistry.fromEnvironment();
        auto doc = extractMarkdown(registry, md);
        auto buf = appender!string;
        renderMarkdownInlineHtml(doc, buf);
        return buf[];
    }
}

@("md.render_html.paragraphInlines")
@system
unittest
{
    import std.algorithm.searching : canFind;
    const html = renderBlock("a **b** _c_ `x` ~~y~~\n");
    assert(html.canFind("<p>a <strong>b</strong> <em>c</em> <code>x</code> "));
    // `~~y~~` parses as a nested `strikethrough` in the bundled grammar (a
    // model-level quirk shared with the GUI preview); we render it faithfully.
    // Nested `<del>` is visually identical to a single one, so assert tolerantly.
    assert(html.canFind("y</del>") && html.canFind("<del>"));
}

@("md.render_html.headingAndEscape")
@system
unittest
{
    assert(renderBlock("# A < B\n") == "<h1>A &lt; B</h1>");
    assert(renderBlock("### three\n") == "<h3>three</h3>");
}

@("md.render_html.codeFence")
@system
unittest
{
    assert(renderBlock("```d\nvoid main() {}\n```\n") ==
        `<pre><code class="language-d">void main() {}` ~ "\n" ~ `</code></pre>`);
}

@("md.render_html.linkAndImage")
@system
unittest
{
    assert(renderBlock("see [text](http://x)\n") ==
        `<p>see <a href="http://x">text</a></p>`);
    assert(renderBlock("![alt](img.png)\n") ==
        `<p><img src="img.png" alt="alt"></p>`);
}

@("md.render_html.list")
@system
unittest
{
    assert(renderBlock("- a\n- b\n") == "<ul><li><p>a</p></li><li><p>b</p></li></ul>");
    assert(renderBlock("1. one\n2. two\n") ==
        "<ol><li><p>one</p></li><li><p>two</p></li></ol>");
}

@("md.render_html.taskList")
@system
unittest
{
    import std.algorithm.searching : canFind;
    const html = renderBlock("- [ ] todo\n- [x] done\n");
    assert(canFind(html, `<input type="checkbox" disabled> `));
    assert(canFind(html, `<input type="checkbox" disabled checked> `));
}

@("md.render_html.table")
@system
unittest
{
    assert(renderBlock("| a | b |\n|---|---|\n| 1 | 2 |\n") ==
        "<table><thead><tr><th>a </th><th>b </th></tr></thead>" ~
        "<tbody><tr><td>1 </td><td>2 </td></tr></tbody></table>");
}

@("md.render_html.blockQuoteAndRule")
@system
unittest
{
    assert(renderBlock("> quoted\n\n---\n") ==
        "<blockquote><p>quoted</p></blockquote><hr>");
}

@("md.render_html.inline.unwrapsParagraph")
@system
unittest
{
    // A single paragraph loses its <p> at the inline entry point …
    assert(renderInline("the `wrapped` object\n") == "the <code>wrapped</code> object");
    // … but richer input falls back to block rendering.
    assert(renderInline("# heading\n") == "<h1>heading</h1>");
}
