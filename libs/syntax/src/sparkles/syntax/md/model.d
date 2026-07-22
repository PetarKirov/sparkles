/**
A structural markdown document model, parsed straight from the bundled
tree-sitter `markdown` + `markdown-inline` grammars.

The highlight event stream (`sparkles.syntax.event`) is deliberately lossy: it
flattens the parse to `(byteRange, LabelId)` runs and discards node kinds,
heading levels, fence languages, and emphasis nesting. A *preview* renderer
(headings sized by level, fenced code panels labelled by language, list bullets,
quote gutters, tables) needs that structure back. Rather than reconstruct it from
labels — which the bundled markdown queries don't even emit (`@text.*` capture
names the `markup.*` vocabulary doesn't map) — this module walks the grammar tree
directly and yields a small block/inline model.

$(B Grammar shape) (MDeiml split grammar, extensions observed in the bundle):
`document → section* → blocks`; sections nest one level per heading and are
walked transparently. Tables (`pipe_table`) and task-list markers are enabled;
definition lists are not (a `term`/`: def` pair parses as a plain paragraph), and
footnote definitions collapse to `link_reference_definition` (not rendered).
Fenced code carries its language in `info_string → language`; inline emphasis /
strong / strikethrough / code spans embed their delimiters as named children with
the visible text in the gaps between them.

Structure only — no colors, no layout. A backend (`hue --gui`'s preview path)
consumes $(LREF MdDoc), highlights each code fence with its own grammar (or the
ANSI renderer for a ` ```ansi ` fence), and paints the result.
*/
module sparkles.syntax.md.model;

import sparkles.syntax.ts.registry : GrammarRegistry, canonicalLanguage;
import sparkles.tree_sitter.errors : TsError;
import sparkles.tree_sitter.tree_sitter_c : TSNode;
import sparkles.tree_sitter.wrappers : TsParser, TsTree, nodeType, nodeStartByte,
    nodeEndByte, nodeNamedChild, nodeNamedChildCount;

/// A byte range `[start, end)` into the document source.
struct Span
{
    size_t start; /// inclusive start byte
    size_t end;   /// exclusive end byte
}

/// The kind of a $(LREF MdBlock). `tableRow`/`tableCell` appear only as the
/// children of a `table`/`tableRow`; `listItem` only under a `list`.
enum MdBlockKind
{
    document,      /// the root; `children` are the document's blocks in order
    heading,       /// `level` 1..6; `inlines` are the heading text
    paragraph,     /// `inlines` are the paragraph text
    codeFence,     /// `infoLang`/`label` + `codeBody` (a source slice)
    blockQuote,    /// `children` are the quoted blocks
    list,          /// `ordered`; `children` are `listItem`s
    listItem,      /// `ordered`/`checkbox`; `children` are the item's blocks
    thematicBreak, /// a horizontal rule
    table,         /// `children` are `tableRow`s (first row is the header)
    tableRow,      /// `children` are `tableCell`s
    tableCell,     /// `inlines` are the cell text
    htmlBlock,     /// raw HTML; `span` covers the verbatim bytes
}

/// A block-level markdown construct. A tree: `list ▸ listItem ▸ paragraph`,
/// `blockQuote ▸ …`, `table ▸ tableRow ▸ tableCell` all nest through `children`.
struct MdBlock
{
    MdBlockKind kind;
    ubyte level;            /// heading level 1..6 (0 otherwise)
    bool ordered;           /// list / listItem: ordered (`1.`) vs bulleted (`-`)
    byte checkbox = -1;     /// listItem task state: -1 none, 0 unchecked, 1 checked
    const(char)[] infoLang; /// codeFence: the info-string language tag (raw), else ""
    const(char)[] label;    /// codeFence: info-string remainder (e.g. "[file.d]"), else ""
    Span codeBody;          /// codeFence: the `code_fence_content` byte extent
    MdInline[] inlines;     /// heading / paragraph / tableCell: resolved inline spans
    MdBlock[] children;     /// nested blocks (see the per-kind notes above)
    Span span;              /// the whole block's byte extent
}

/// The kind of an $(LREF MdInline) span.
enum MdInlineKind
{
    text,          /// literal text (a source slice)
    emphasis,      /// `*em*` — `children` are the inner spans
    strong,        /// `**strong**` — `children` are the inner spans
    strikethrough, /// `~~del~~` — `children` are the inner spans
    codeSpan,      /// `` `code` `` — literal; render `span` verbatim
    link,          /// `[text](dest)` — `children` are the label; `linkDest` the URL
    image,         /// `![alt](src)` — `children` are the alt text; `linkDest` the src
    lineBreak,     /// a hard line break
}

/// An inline (span-level) markdown construct. Nested styling (a bold link, a
/// strong-inside-emphasis) recurses through `children`; a leaf `text`/`codeSpan`
/// has none and is rendered from `span`.
struct MdInline
{
    MdInlineKind kind;
    Span span;              /// the styled content extent (delimiters excluded)
    MdInline[] children;    /// nested spans (emphasis/strong/strikethrough/link/image)
    const(char)[] linkDest; /// link/image destination (raw), else ""
}

/// A parsed markdown document: the block tree plus the source it indexes into.
struct MdDoc
{
    MdBlock root;         /// a `document` block
    const(char)[] source; /// the bytes every `Span` slices
}

/**
Parses `source` as markdown and returns its structural model. Grammars come from
`registry` (the bundled `markdown` + `markdown-inline`); a missing grammar or a
failed parse yields a `document` with no children (the caller falls back to the
raw view). GC-allocating and `@system` — run once at file load, never per frame.
*/
MdDoc extractMarkdown(ref GrammarRegistry registry, scope const(char)[] source) @system
{
    MdDoc doc;
    doc.source = source;
    doc.root.kind = MdBlockKind.document;
    doc.root.span = Span(0, source.length);

    auto block = registry.grammar("markdown");
    auto inline = registry.grammar("markdown-inline");
    if (block.hasError || inline.hasError)
        return doc;

    auto blockParser = TsParser.create();
    if (blockParser.setLanguage(block.value.language).hasError)
        return doc;

    auto inlineParser = TsParser.create();
    if (inlineParser.setLanguage(inline.value.language).hasError)
        return doc;

    TsError err;
    auto tree = blockParser.parse(source, err);
    if (!tree.valid)
        return doc;

    // Blank the block grammar's `block_continuation` markers (the lazy `> ` on a
    // wrapped quote/list line) in a length-preserving working copy: they live
    // inside a paragraph's inline node, but the inline grammar we re-parse with
    // treats `>` as literal text, so they'd otherwise leak into the rendered
    // prose. Blanking keeps every byte offset valid for both buffers.
    auto cleaned = source.dup;
    blankContinuations(tree.rootNode, cleaned);
    doc.source = cleaned;

    auto ex = Extractor(cleaned, &inlineParser);
    doc.root.children = ex.walkBlocks(tree.rootNode);
    return doc;
}

private void blankContinuations(TSNode n, char[] buf) @trusted nothrow
{
    if (nodeType(n) == "block_continuation")
        foreach (k; nodeStartByte(n) .. nodeEndByte(n))
            if (k < buf.length)
                buf[k] = ' ';
    foreach (i; 0 .. nodeNamedChildCount(n))
        blankContinuations(nodeNamedChild(n, i), buf);
}

// ─────────────────────────────────────────────────────────────────────────────

private struct Extractor
{
    const(char)[] source;
    TsParser* inlineParser;

    const(char)[] textOf(TSNode n) @trusted nothrow
        => source[nodeStartByte(n) .. nodeEndByte(n)];

    // The first named child of `n` whose type is `type`, or a sentinel `found`
    // flag = false. (`TSNode` is a POD with no null we can test portably, so the
    // caller checks `found`.)
    bool firstChild(TSNode n, string type, out TSNode child) @trusted nothrow
    {
        foreach (i; 0 .. nodeNamedChildCount(n))
        {
            auto c = nodeNamedChild(n, i);
            if (nodeType(c) == type)
            {
                child = c;
                return true;
            }
        }
        return false;
    }

    // Walk block-level children of `parent`, splicing `section` wrappers away so
    // the result is the document's blocks in reading order.
    MdBlock[] walkBlocks(TSNode parent) @trusted nothrow
    {
        MdBlock[] blocks;
        foreach (i; 0 .. nodeNamedChildCount(parent))
        {
            auto ch = nodeNamedChild(parent, i);
            const t = nodeType(ch);
            switch (t)
            {
            case "section":
                blocks ~= walkBlocks(ch); // transparent — sections just nest headings
                break;
            case "atx_heading":
            case "setext_heading":
                blocks ~= heading(ch, t == "setext_heading");
                break;
            case "paragraph":
                blocks ~= para(ch);
                break;
            case "fenced_code_block":
            case "indented_code_block":
                blocks ~= codeFence(ch);
                break;
            case "block_quote":
                blocks ~= quote(ch);
                break;
            case "list":
                blocks ~= list(ch);
                break;
            case "thematic_break":
                blocks ~= MdBlock(kind: MdBlockKind.thematicBreak, span: extent(ch));
                break;
            case "pipe_table":
                blocks ~= table(ch);
                break;
            case "html_block":
                blocks ~= MdBlock(kind: MdBlockKind.htmlBlock, span: extent(ch));
                break;
            // link_reference_definition (incl. footnote defs) render nothing —
            // reference definitions are invisible in a rendered preview.
            default:
                break;
            }
        }
        return blocks;
    }

    Span extent(TSNode n) @trusted nothrow
        => Span(nodeStartByte(n), nodeEndByte(n));

    MdBlock heading(TSNode n, bool setext) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.heading, span: extent(n)};
        // Level: an atx_hN_marker child, or a setext_hN_underline (h1/h2 only).
        foreach (i; 0 .. nodeNamedChildCount(n))
        {
            const ct = nodeType(nodeNamedChild(n, i)); // e.g. "atx_h3_marker"
            if (ct.length == 13 && ct[0 .. 5] == "atx_h" && ct[6] == '_' && ct[7 .. $] == "marker")
            {
                b.level = cast(ubyte)(ct[5] - '0');
                break;
            }
            if (ct == "setext_h1_underline")
                b.level = 1;
            else if (ct == "setext_h2_underline")
                b.level = 2;
        }
        if (b.level == 0)
            b.level = 1;
        // Content: the `inline` child (atx) or the paragraph's inline (setext).
        TSNode host = n, inl;
        if (setext && firstChild(n, "paragraph", host)) {}
        if (firstChild(host, "inline", inl))
            b.inlines = parseInline(nodeStartByte(inl), nodeEndByte(inl));
        return b;
    }

    MdBlock para(TSNode n) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.paragraph, span: extent(n)};
        TSNode inl;
        if (firstChild(n, "inline", inl))
            b.inlines = parseInline(nodeStartByte(inl), nodeEndByte(inl));
        return b;
    }

    MdBlock codeFence(TSNode n) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.codeFence, span: extent(n)};
        TSNode info, lang, body;
        if (firstChild(n, "info_string", info))
        {
            if (firstChild(info, "language", lang))
            {
                b.infoLang = textOf(lang);
                // The info-string remainder after the language (e.g. "[file.d]").
                const rest = source[nodeEndByte(lang) .. nodeEndByte(info)];
                b.label = strip(rest);
            }
            else
                b.infoLang = strip(textOf(info));
        }
        if (firstChild(n, "code_fence_content", body))
            b.codeBody = extent(body);
        return b;
    }

    MdBlock quote(TSNode n) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.blockQuote, span: extent(n)};
        b.children = walkBlocks(n);
        return b;
    }

    MdBlock list(TSNode n) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.list, span: extent(n)};
        foreach (i; 0 .. nodeNamedChildCount(n))
        {
            auto ch = nodeNamedChild(n, i);
            if (nodeType(ch) == "list_item")
                b.children ~= listItem(ch);
        }
        if (b.children.length)
            b.ordered = b.children[0].ordered;
        return b;
    }

    MdBlock listItem(TSNode n) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.listItem, span: extent(n)};
        foreach (i; 0 .. nodeNamedChildCount(n))
        {
            auto ch = nodeNamedChild(n, i);
            switch (nodeType(ch))
            {
            case "list_marker_dot":
            case "list_marker_parenthesis":
                b.ordered = true;
                break;
            case "list_marker_minus":
            case "list_marker_plus":
            case "list_marker_star":
                b.ordered = false;
                break;
            case "task_list_marker_checked":
                b.checkbox = 1;
                break;
            case "task_list_marker_unchecked":
                b.checkbox = 0;
                break;
            default:
                break;
            }
        }
        b.children = walkBlocks(n); // markers are skipped by walkBlocks
        return b;
    }

    MdBlock table(TSNode n) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.table, span: extent(n)};
        foreach (i; 0 .. nodeNamedChildCount(n))
        {
            auto row = nodeNamedChild(n, i);
            const rt = nodeType(row);
            if (rt == "pipe_table_header" || rt == "pipe_table_row")
                b.children ~= tableRow(row);
            // pipe_table_delimiter_row (|---|---|) carries no content — skip.
        }
        return b;
    }

    MdBlock tableRow(TSNode n) @trusted nothrow
    {
        MdBlock b = {kind: MdBlockKind.tableRow, span: extent(n)};
        foreach (i; 0 .. nodeNamedChildCount(n))
        {
            auto cell = nodeNamedChild(n, i);
            if (nodeType(cell) == "pipe_table_cell")
            {
                MdBlock c = {kind: MdBlockKind.tableCell, span: extent(cell)};
                c.inlines = parseInline(nodeStartByte(cell), nodeEndByte(cell));
                b.children ~= c;
            }
        }
        return b;
    }

    // Parse the source slice `[lo, hi)` with markdown-inline and return the
    // resolved inline spans in absolute (document) byte coordinates.
    MdInline[] parseInline(size_t lo, size_t hi) @trusted nothrow
    {
        if (hi <= lo)
            return null;
        TsError err;
        auto tree = inlineParser.parse(source[lo .. hi], err);
        if (!tree.valid)
            return [MdInline(kind: MdInlineKind.text, span: Span(lo, hi))];
        MdInline[] out_;
        walkInline(tree.rootNode, lo, 0, hi - lo, out_);
        return out_;
    }

    // Walk the inline container `n` (an `inline` node, or an emphasis/link inner
    // range), covering `[clo, chi)` (slice-relative) with text gaps between named
    // children. `base` is the document offset added to every emitted span.
    void walkInline(TSNode n, size_t base, size_t clo, size_t chi, ref MdInline[] out_) @trusted nothrow
    {
        size_t cur = clo;
        void gap(size_t upto)
        {
            if (upto > cur)
            {
                out_ ~= MdInline(kind: MdInlineKind.text, span: Span(base + cur, base + upto));
                cur = upto;
            }
        }

        foreach (i; 0 .. nodeNamedChildCount(n))
        {
            auto ch = nodeNamedChild(n, i);
            const cs = nodeStartByte(ch), ce = nodeEndByte(ch), t = nodeType(ch);
            if (cs < clo || ce > chi || ce <= cur) // delimiter outside content, or already covered
                continue;
            gap(cs);
            switch (t)
            {
            case "emphasis":
                out_ ~= styled(ch, MdInlineKind.emphasis, base);
                cur = ce;
                break;
            case "strong_emphasis":
                out_ ~= styled(ch, MdInlineKind.strong, base);
                cur = ce;
                break;
            case "strikethrough":
                out_ ~= styled(ch, MdInlineKind.strikethrough, base);
                cur = ce;
                break;
            case "code_span":
                out_ ~= codeSpan(ch, base);
                cur = ce;
                break;
            case "inline_link":
            case "shortcut_link":
                out_ ~= link(ch, base);
                cur = ce;
                break;
            case "image":
                out_ ~= image(ch, base);
                cur = ce;
                break;
            case "uri_autolink":
                out_ ~= MdInline(kind: MdInlineKind.link, span: Span(base + cs, base + ce),
                    linkDest: source[base + cs .. base + ce]);
                cur = ce;
                break;
            case "hard_line_break":
                out_ ~= MdInline(kind: MdInlineKind.lineBreak, span: Span(base + cs, base + ce));
                cur = ce;
                break;
            case "block_continuation":
                cur = ce; // a quote/list continuation marker — render nothing
                break;
            // html_tag, backslash_escape, unknown → render their bytes literally.
            default:
                gap(ce);
                break;
            }
        }
        gap(chi);
    }

    // A delimited container (emphasis/strong/strikethrough): the content lies
    // between the leading and trailing `*_delimiter` children.
    MdInline styled(TSNode n, MdInlineKind kind, size_t base) @trusted nothrow
    {
        const inner = trimDelims(n);
        MdInline s = {kind: kind, span: Span(base + inner.start, base + inner.end)};
        walkInline(n, base, inner.start, inner.end, s.children);
        return s;
    }

    MdInline codeSpan(TSNode n, size_t base) @trusted nothrow
    {
        const inner = trimDelims(n);
        return MdInline(kind: MdInlineKind.codeSpan,
            span: Span(base + inner.start, base + inner.end));
    }

    MdInline link(TSNode n, size_t base) @trusted nothrow
    {
        MdInline s = {kind: MdInlineKind.link, span: Span(base + nodeStartByte(n),
                base + nodeEndByte(n))};
        TSNode dest;
        if (firstChild(n, "link_destination", dest))
            s.linkDest = source[base + nodeStartByte(dest) .. base + nodeEndByte(dest)];
        TSNode txt;
        if (firstChild(n, "link_text", txt))
            walkInline(txt, base, nodeStartByte(txt), nodeEndByte(txt), s.children);
        return s;
    }

    MdInline image(TSNode n, size_t base) @trusted nothrow
    {
        MdInline s = {kind: MdInlineKind.image, span: Span(base + nodeStartByte(n),
                base + nodeEndByte(n))};
        TSNode dest;
        if (firstChild(n, "link_destination", dest))
            s.linkDest = source[base + nodeStartByte(dest) .. base + nodeEndByte(dest)];
        TSNode alt;
        if (firstChild(n, "image_description", alt))
            s.children ~= MdInline(kind: MdInlineKind.text,
                span: Span(base + nodeStartByte(alt), base + nodeEndByte(alt)));
        return s;
    }

    // The content extent of a delimited node: its byte range minus the leading
    // and trailing `*_delimiter` children. Slice-relative when `base` handling is
    // done by the caller; here we return absolute-to-the-node coordinates.
    Span trimDelims(TSNode n) @trusted nothrow
    {
        size_t lo = nodeStartByte(n), hi = nodeEndByte(n);
        const cnt = nodeNamedChildCount(n);
        foreach (i; 0 .. cnt) // leading
        {
            auto ch = nodeNamedChild(n, i);
            if (isDelim(nodeType(ch)) && nodeStartByte(ch) == lo)
                lo = nodeEndByte(ch);
            else
                break;
        }
        foreach_reverse (i; 0 .. cnt) // trailing
        {
            auto ch = nodeNamedChild(n, i);
            if (isDelim(nodeType(ch)) && nodeEndByte(ch) == hi)
                hi = nodeStartByte(ch);
            else
                break;
        }
        return hi >= lo ? Span(lo, hi) : Span(lo, lo);
    }
}

private bool isDelim(const(char)[] t) @safe pure nothrow @nogc
{
    // "emphasis_delimiter", "code_span_delimiter", …
    return t.length > 10 && t[$ - 10 .. $] == "_delimiter";
}

private const(char)[] strip(const(char)[] s) @safe pure nothrow @nogc
{
    size_t a, b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\n')) --b;
    return s[a .. b];
}

// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // Parse `src` and return its document blocks (grammar-bundle gated).
    private MdDoc extractForTest(string src) @system
    {
        import std.process : environment;
        import sparkles.test_runner.skip : skipTest;

        if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
        auto registry = GrammarRegistry.fromEnvironment();
        return extractMarkdown(registry, src);
    }

    // Text of a block's inline spans concatenated (leaf text/codeSpan only).
    private string inlineText(in MdDoc d, in MdBlock b) @safe
    {
        string s;
        foreach (inl; b.inlines)
            s ~= d.source[inl.span.start .. inl.span.end];
        return s;
    }
}

@("md.model.headings")
@system
unittest
{
    auto d = extractForTest("# One\n\n## Two\n\n### Three\n");
    auto h = d.root.children;
    assert(h.length == 3);
    assert(h[0].kind == MdBlockKind.heading && h[0].level == 1);
    assert(h[1].level == 2 && h[2].level == 3);
    assert(inlineText(d, h[0]) == "One");
    assert(inlineText(d, h[2]) == "Three");
}

@("md.model.inline.emphasisStrongCode")
@system
unittest
{
    auto d = extractForTest("a **b** _c_ `x` ~~y~~\n");
    auto p = d.root.children[0];
    assert(p.kind == MdBlockKind.paragraph);
    MdInlineKind[] kinds;
    foreach (inl; p.inlines)
        kinds ~= inl.kind;
    import std.algorithm.searching : canFind;
    assert(kinds.canFind(MdInlineKind.strong));
    assert(kinds.canFind(MdInlineKind.emphasis));
    assert(kinds.canFind(MdInlineKind.codeSpan));
    assert(kinds.canFind(MdInlineKind.strikethrough));
    // strong content excludes the ** delimiters
    foreach (inl; p.inlines)
        if (inl.kind == MdInlineKind.strong)
            assert(d.source[inl.span.start .. inl.span.end] == "b");
}

@("md.model.codeFence.langAndBody")
@system
unittest
{
    auto d = extractForTest("```d [file.d]\nvoid main() {}\n```\n\n```ansi\nx\n```\n");
    auto blocks = d.root.children;
    assert(blocks.length == 2);
    assert(blocks[0].kind == MdBlockKind.codeFence);
    assert(blocks[0].infoLang == "d");
    assert(blocks[0].label == "[file.d]");
    assert(d.source[blocks[0].codeBody.start .. blocks[0].codeBody.end] == "void main() {}\n");
    assert(blocks[1].infoLang == "ansi");
}

@("md.model.lists.nestedAndTasks")
@system
unittest
{
    auto d = extractForTest("- a\n- b\n  - c\n\n1. one\n2. two\n\n- [ ] todo\n- [x] done\n");
    auto blocks = d.root.children;
    // bulleted list, ordered list, task list
    auto ul = blocks[0];
    assert(ul.kind == MdBlockKind.list && !ul.ordered);
    assert(ul.children.length == 2);
    // second item nests a sub-list
    import std.algorithm.searching : any;
    assert(ul.children[1].children.any!(c => c.kind == MdBlockKind.list));

    auto ol = blocks[1];
    assert(ol.kind == MdBlockKind.list && ol.ordered);

    auto tl = blocks[2];
    assert(tl.children[0].checkbox == 0);
    assert(tl.children[1].checkbox == 1);
}

@("md.model.quoteAndRule")
@system
unittest
{
    auto d = extractForTest("> quoted\n> more\n\n---\n");
    auto blocks = d.root.children;
    assert(blocks[0].kind == MdBlockKind.blockQuote);
    assert(blocks[0].children.length >= 1);
    assert(blocks[1].kind == MdBlockKind.thematicBreak);
}

@("md.model.table")
@system
unittest
{
    auto d = extractForTest("| a | b |\n|---|---|\n| 1 | 2 |\n");
    auto t = d.root.children[0];
    assert(t.kind == MdBlockKind.table);
    assert(t.children.length == 2);        // header + one body row (delimiter row skipped)
    assert(t.children[0].kind == MdBlockKind.tableRow);
    assert(t.children[0].children.length == 2); // two cells
    import std.string : strip;
    assert(inlineText(d, t.children[0].children[0]).strip == "a");
}

@("md.model.linkAndImage")
@system
unittest
{
    auto d = extractForTest("see [text](http://x) and ![alt](img.png)\n");
    auto p = d.root.children[0];
    MdInline* linkP, imgP;
    foreach (ref inl; p.inlines)
    {
        if (inl.kind == MdInlineKind.link) linkP = &inl;
        if (inl.kind == MdInlineKind.image) imgP = &inl;
    }
    assert(linkP !is null && linkP.linkDest == "http://x");
    assert(imgP !is null && imgP.linkDest == "img.png");
}

@("md.model.htmlBlock")
@system
unittest
{
    auto d = extractForTest("<div>raw</div>\n");
    assert(d.root.children[0].kind == MdBlockKind.htmlBlock);
}
