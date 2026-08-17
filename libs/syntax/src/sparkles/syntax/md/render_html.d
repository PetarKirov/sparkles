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

$(B Scope.) Structure and inline styling, plus three presentation features that
mirror the GUI preview: per-column table alignment (`text-align` from the model's
delimiter-row `ColAlign`), GitHub callouts (`> [!NOTE]` → `<div class="callout
callout-note">`), and syntax-highlighted fences via an optional `fence` hook.

By default fenced code is emitted as an escaped `<pre><code class="language-…">`
block — this module deliberately does $(B not) re-highlight it (that would couple
it to a grammar registry). A caller with a highlighter passes a `fence` callable
(`(lang, code) → html`); returning empty falls back to the default. The hook is a
$(B template parameter) guarded by `static if`, so the default instantiation (no
hook) stays `@safe pure nothrow @nogc` — only a hooked call takes on the hook's
attributes. Raw `htmlBlock`s pass through verbatim (standard markdown semantics —
the doc author's HTML). Everything else is escaped via
$(REF writeHtmlEscaped, sparkles,base,text,html).

Totality: never fails on any `MdDoc`; an empty document emits nothing.
*/
module sparkles.syntax.md.render_html;

import std.range.primitives : put;

import sparkles.base.text.html : writeHtmlEscaped;

import sparkles.syntax.md.model : ColAlign, MdBlock, MdBlockKind, MdDoc, MdInline,
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

`w` is any `char` output range; attributes infer (a `@nogc` writer + no `fence`
hook keeps the whole walk `@nogc`).

`fence`, when passed, is called for each fenced code block as `fence(lang, code)`
— `lang` the raw info-string language tag, `code` the raw (unescaped) body — and
must return the block's full replacement HTML (typically a `<pre>…</pre>`).
Returning an empty slice falls back to the default escaped `<pre><code>`. It lets
a caller with a grammar registry emit highlighted doc-code without this module
depending on one.
*/
ref Writer renderMarkdownHtml(Writer, Fence = typeof(null))(
    in MdDoc doc,
    return ref Writer w,
    in MarkdownHtmlOptions options = MarkdownHtmlOptions(),
    Fence fence = null,
)
{
    foreach (ref const b; doc.root.children)
        writeBlock(w, doc.source, b, options, fence);
    return w;
}

/**
Renders `doc` as $(B inline) HTML into `w`. When the document is a single
paragraph its inlines are emitted $(B without) the surrounding `<p>` (the common
case for a one-line JSDoc tag value); anything richer — multiple blocks, a
heading, a list — falls back to $(LREF renderMarkdownHtml). Returns `w`.
*/
ref Writer renderMarkdownInlineHtml(Writer, Fence = typeof(null))(
    in MdDoc doc,
    return ref Writer w,
    in MarkdownHtmlOptions options = MarkdownHtmlOptions(),
    Fence fence = null,
)
{
    const blocks = doc.root.children;
    if (blocks.length == 1 && blocks[0].kind == MdBlockKind.paragraph)
        writeInlines(w, doc.source, blocks[0].inlines);
    else
        renderMarkdownHtml(doc, w, options, fence);
    return w;
}

// ─────────────────────────────────────────────────────────────────────────────

private void writeBlock(Writer, Fence)(ref Writer w, scope const(char)[] src,
    in MdBlock b, in MarkdownHtmlOptions options, Fence fence)
{
    final switch (b.kind)
    {
        case MdBlockKind.document:
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options, fence);
            break;

        case MdBlockKind.codeGroup:
            // The group is a container, and its fences already carry their
            // own labels; a tabbed rendering here wants the checked-radio
            // idiom ([`WGT23`](../../specs/ui/widgets.md)) and lands with
            // it. Until then the class is the hook and every fence shows,
            // which is the honest degradation — nothing is hidden.
            w.put("<div class=\"code-group\">\n");
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options, fence);
            w.put("</div>\n");
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
            static if (!is(Fence == typeof(null)))
            {
                // A highlighter hook: let it emit the block; empty → fall back.
                const rendered = fence(b.infoLang, slice(src, b.codeBody));
                if (rendered.length)
                {
                    put(w, rendered);
                    break;
                }
            }
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
            // A GitHub callout (`> [!NOTE]`) renders as a titled `<div>`; a plain
            // quote as `<blockquote>`.
            if (writeCalloutIfAny(w, src, b, options, fence))
                break;
            put(w, "<blockquote>");
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options, fence);
            put(w, "</blockquote>");
            break;

        case MdBlockKind.list:
            const tag = b.ordered ? "ol" : "ul";
            put(w, "<"); put(w, tag); put(w, ">");
            foreach (ref const c; b.children)
                writeBlock(w, src, c, options, fence);
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
                writeBlock(w, src, c, options, fence);
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

// A `blockQuote` whose first paragraph opens with a GitHub `[!TYPE]` marker
// renders as `<div class="callout callout-<type>"><p class="callout-title">…`,
// with the marker stripped from the body. Detection reads the paragraph's raw
// source (not the parsed inlines: `[!NOTE]` parses as a *shortcut link*, not
// text) — the same technique the GUI preview uses. Returns false (emit a plain
// quote) when there is no marker.
private bool writeCalloutIfAny(Writer, Fence)(ref Writer w, scope const(char)[] src,
    in MdBlock b, in MarkdownHtmlOptions options, Fence fence)
{
    const(MdBlock)* p;
    foreach (ref const c; b.children)
        if (c.kind == MdBlockKind.paragraph)
        {
            p = &c;
            break;
        }
    if (p is null)
        return false;

    const txt = slice(src, p.span);
    size_t i;
    while (i < txt.length && (txt[i] == ' ' || txt[i] == '\t'))
        ++i;
    if (i + 2 >= txt.length || txt[i] != '[' || txt[i + 1] != '!')
        return false;
    const s = i + 2;
    size_t e = s;
    while (e < txt.length && txt[e] != ']')
        ++e;
    string typ, title;
    if (e >= txt.length || !calloutType(txt[s .. e], typ, title))
        return false;

    const cutoff = p.span.start + e + 1; // through the closing `]`
    put(w, `<div class="callout callout-`); put(w, typ); put(w, `">`);
    put(w, `<p class="callout-title">`); put(w, title); put(w, `</p>`);
    bool firstPara = true;
    foreach (ref const c; b.children)
    {
        if (c.kind == MdBlockKind.paragraph && firstPara)
        {
            firstPara = false;
            put(w, "<p>");
            writeInlinesFrom(w, src, c.inlines, cutoff);
            put(w, "</p>");
        }
        else
            writeBlock(w, src, c, options, fence);
    }
    put(w, `</div>`);
    return true;
}

// Renders `inlines` but drops everything before byte `cutoff` (the `[!TYPE]`
// marker), slicing a straddling leading `text` inline — mirrors the GUI's
// `trimLeadingBytes`. A leading whitespace run in the first kept text is trimmed
// so the body doesn't open with the space after `]`.
private void writeInlinesFrom(Writer)(ref Writer w, scope const(char)[] src,
    in MdInline[] inlines, size_t cutoff)
{
    bool leading = true;
    foreach (ref const inl; inlines)
    {
        if (inl.span.end <= cutoff)
            continue;
        if (inl.span.start < cutoff && inl.kind == MdInlineKind.text)
        {
            auto t = slice(src, Span(cutoff, inl.span.end));
            if (leading)
                t = lstripAscii(t);
            leading = false;
            writeHtmlEscaped(w, t);
        }
        else
        {
            if (leading && inl.kind == MdInlineKind.lineBreak)
                continue; // skip a hard break sitting right after the marker
            leading = false;
            writeInline(w, src, inl);
        }
    }
}

// The first row of a `table` is the header (`<th>` in a `<thead>`); the rest are
// `<td>` body rows. Per-column `text-align` comes from the model's delimiter-row
// `aligns` (`:--`/`:-:`/`--:`); `none`/`left` add no attribute.
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
        foreach (ci, ref const cell; row.children)
        {
            put(w, "<"); put(w, cellTag);
            put(w, alignStyle(ci < t.aligns.length ? t.aligns[ci] : ColAlign.none));
            put(w, ">");
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

// Left-trim ASCII whitespace (spaces, tabs, CR/LF).
private const(char)[] lstripAscii(return scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t i;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
        ++i;
    return s[i .. $];
}

// The inline `style` attribute for a column alignment (empty for none/left).
private string alignStyle(ColAlign a) @safe pure nothrow @nogc
{
    final switch (a)
    {
        case ColAlign.none:
        case ColAlign.left:   return "";
        case ColAlign.center: return ` style="text-align:center"`;
        case ColAlign.right:  return ` style="text-align:right"`;
    }
}

// Case-insensitively match a `[!TYPE]` marker against the 5 GitHub callout types;
// `b` is already uppercase. Allocation-free, so callout detection keeps the
// default walk `@nogc`.
private bool eqIC(const(char)[] a, string b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i, char c; a)
    {
        const u = (c >= 'a' && c <= 'z') ? cast(char)(c - 32) : c;
        if (u != b[i])
            return false;
    }
    return true;
}

private bool calloutType(const(char)[] type, out string typ, out string title)
    @safe pure nothrow @nogc
{
    if (eqIC(type, "NOTE"))      { typ = "note";      title = "Note";      return true; }
    if (eqIC(type, "TIP"))       { typ = "tip";       title = "Tip";       return true; }
    if (eqIC(type, "IMPORTANT")) { typ = "important"; title = "Important"; return true; }
    if (eqIC(type, "WARNING"))   { typ = "warning";   title = "Warning";   return true; }
    if (eqIC(type, "CAUTION"))   { typ = "caution";   title = "Caution";   return true; }
    return false;
}

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

@("md.render_html.fenceHook")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.smallbuffer : SmallBuffer;
    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
    auto registry = GrammarRegistry.fromEnvironment();
    auto doc = extractMarkdown(registry, "```d\nvoid main() {}\n```\n");
    SmallBuffer!(char, 512) buf;
    // A hook that wraps the body in its own element replaces the default fence.
    renderMarkdownHtml(doc, buf, MarkdownHtmlOptions(),
        (const(char)[] lang, const(char)[] code) => cast(const(char)[])(
            `<pre class="hl" data-lang="` ~ lang.idup ~ `">` ~ code.idup ~ `</pre>`));
    assert(buf[].canFind(`<pre class="hl" data-lang="d">void main() {}`), buf[]);
    assert(!buf[].canFind("<code"), "the fence hook must replace the default block");
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

@("md.render_html.tableAlignment")
@system
unittest
{
    import std.algorithm.searching : canFind;
    // `:--` left (no style), `:-:` center, `--:` right.
    const html = renderBlock("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n");
    assert(html.canFind(`<th>a </th>`), html);
    assert(html.canFind(`<th style="text-align:center">b </th>`), html);
    assert(html.canFind(`<th style="text-align:right">c </th>`), html);
    assert(html.canFind(`<td style="text-align:right">3 </td>`), html);
}

@("md.render_html.callout")
@system
unittest
{
    import std.algorithm.searching : canFind;
    const html = renderBlock("> [!NOTE]\n> Body text.\n");
    assert(html.canFind(`<div class="callout callout-note">`), html);
    assert(html.canFind(`<p class="callout-title">Note</p>`), html);
    assert(html.canFind("Body text."), html);
    assert(html.canFind("</div>"), html);
    // The `[!NOTE]` marker must not leak into the rendered body.
    assert(!html.canFind("[!NOTE]"), html);
    // A plain quote (no marker) stays a <blockquote>.
    assert(renderBlock("> just a quote\n") == "<blockquote><p>just a quote</p></blockquote>");
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
