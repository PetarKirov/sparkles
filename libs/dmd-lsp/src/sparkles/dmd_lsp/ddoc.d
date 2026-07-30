/**
DDoc → CommonMark translation for tooltips (spec `DOC2`/`DOC3`,
`docs/specs/dmd-lsp/ddoc.md`).

This drives DMD's $(B own) documentation engine — `DocComment.parse`,
`Section.write`/`highlightText` (section split, Markdown processing,
parameter/symbol auto-emphasis, code-block extraction), `MacroTable.expand` —
made visible by the `+ls.2` fork patch, and steers the output to CommonMark
by supplying a $(B markdown-emitting macro table) instead of the HTML theme:
the engine still emits `$(DDOC_*)`/`$(EM …)`/`$(D_CODE …)` calls, but they
expand to `**…**`, fenced code blocks, `[text](url)` links, and so on.

Section routing follows the JSDoc/twoslash reference shape
(`15-markdown-docs`): Summary + Description + `Examples:` + custom sections
form the `docs` body; `Params:` rows and the other standard sections become
`[name, text]` tag pairs. Two deliberate divergences from `dmd -D`:

$(LIST
    * Undefined macros $(B never vanish) — dmd's `DDOC_UNDEFINED_MACRO`
        default deletes the whole invocation, which would blank most
        Phobos-style docs (`$(REF …)`, `$(LREF …)` are dlang.org macros, not
        compiler builtins). Here the common dlang.org vocabulary is shimmed
        and anything still unknown renders its arguments.
    * Output is CommonMark, not HTML: `<`, `>`, `&` pass through raw (the
        downstream markdown renderer escapes), and `$(DDOC_COMMENT …)`
        drops instead of emitting an HTML comment.
)
*/
module sparkles.dmd_lsp.ddoc;

import dmd.common.outbuffer : OutBuffer;
import dmd.dmacro : MacroTable;
import dmd.doc : DocComment, escapetable, highlightText, isIdStart, isIdTail,
    ParamSection, Section;
import dmd.dscope : Scope;
import dmd.dsymbol : Dsymbol;
import dmd.dsymbolsem : scopeCreateGlobal;
import dmd.globals : global;

/// The translated documentation of one symbol.
struct DdocRendered
{
    /// Summary + description + Examples + custom sections, as CommonMark.
    string docs;

    /// `[name, text]` chip pairs: one `["param", "x desc"]` per `Params:`
    /// row, plus returns/throws/see/deprecated/… (lowercase names).
    string[][] tags;
}

/// Row separators the `Params:` recovery macros emit (see `defineMacros`).
private enum char rowSep = '\x03';
private enum char idSep = '\x02';

/**
Renders `sym`'s doc comment. `sc` may be null — a global scope for the
symbol's module is created on demand (analysis must have run; call inside a
live `Analyzer` session only).
*/
DdocRendered renderDdoc(Dsymbol sym, Scope* sc = null) @system
{
    import core.stdc.string : strlen;

    if (sym is null || sym.comment is null)
        return DdocRendered.init;

    const comment = sym.comment[0 .. strlen(sym.comment)];
    return renderDdocText(comment.idup, sym, sc);
}

/// ditto, over an explicit comment text (the lexer-stripped form stored on
/// `Dsymbol.comment`).
DdocRendered renderDdocText(string comment, Dsymbol sym, Scope* sc = null) @system
{
    import std.string : strip, toStringz;

    if (!comment.length || sym is null)
        return DdocRendered.init;

    if (sc is null)
    {
        auto mod = sym.getModule();
        if (mod is null)
            return DdocRendered(docs: comment.strip);
        sc = scopeCreateGlobal(mod, global.errorSink);
    }

    auto dc = DocComment.parse(sym, comment.toStringz);

    MacroTable table;
    defineMacros(table);
    // A user `Macros:` section still overrides the builtins (spec order).
    if (dc.macros !is null)
        DocComment.parseMacros(escapetable(sym.getModule()), table, dc.macros.body_);

    const loc = sym.loc;
    DdocRendered result;
    OutBuffer docs;

    foreach (i, sec; dc.sections[])
    {
        if (sec is null)
            continue;
        const name = sectionNameLower(sec.name);

        if (name == "macros")
            continue;

        if (auto ps = cast(ParamSection) sec)
        {
            // DMD's own `ident = desc` row parser (continuations included);
            // the recovery macros mark the row/field boundaries.
            OutBuffer rows;
            ps.write(loc, dc, sc, &dc.a, rows);
            expandWith(table, rows);
            foreach (row; splitCtl(stripSentinels(rows[].idup), rowSep))
            {
                const at = indexOfCtl(row, idSep);
                if (at < 0)
                    continue;
                import std.string : strip;

                const id = bareParamName(row[0 .. at]);
                const desc = collapseWhitespace(row[at + 1 .. $]);
                if (!id.length)
                    continue;
                result.tags ~= ["param", desc.length ? id ~ " " ~ desc : id];
            }
            continue;
        }

        // Everything else runs through the real engine (markdown, links,
        // auto-emphasis, code blocks) into one buffer per section.
        OutBuffer body_;
        {
            const o = body_.length;
            body_.write(sec.body_);
            highlightText(sc, &dc.a, loc, body_, o);
        }
        expandWith(table, body_);
        import std.string : strip;

        const text = cleanupMarkdown(body_[].idup).strip;
        if (!text.length)
            continue;

        if (!sec.name.length)
        {
            // Summary (i == 0) and Description both land in the docs body.
            appendBlock(docs, text);
        }
        else if (const tag = tagNameFor(name))
        {
            result.tags ~= [tag, text];
        }
        else if (name == "examples")
        {
            appendBlock(docs, "### Examples");
            appendBlock(docs, text);
        }
        else
        {
            // Custom section: heading with underscores as spaces.
            import std.array : replace;

            appendBlock(docs, "### " ~ headingCase(sec.name.idup));
            appendBlock(docs, text);
        }
    }

    import std.string : strip;

    result.docs = docs[].idup.strip;
    return result;
}

/// The `Params:` row description for one parameter name, or null.
string paramDocFor(in DdocRendered rendered, scope const(char)[] paramName) @safe pure
{
    import std.algorithm.searching : startsWith;

    foreach (tag; rendered.tags)
    {
        if (tag.length < 2 || tag[0] != "param")
            continue;
        const text = tag[1];
        if (text.startsWith(paramName)
            && (text.length == paramName.length || text[paramName.length] == ' '))
            return text.length == paramName.length ? ""
                : text[paramName.length + 1 .. $];
    }
    return null;
}

// -- section routing ---------------------------------------------------------

private string sectionNameLower(scope const(char)[] name) @safe pure
{
    import std.ascii : toLower;
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.utf : byChar;

    return name.byChar.map!(c => cast(char) c.toLower).array;
}

/// Standard sections that become chips (lowercase JSDoc-parity names).
private string tagNameFor(scope const(char)[] lower) @safe pure nothrow @nogc
{
    switch (lower)
    {
        case "returns": return "returns";
        case "throws": return "throws";
        case "see_also": return "see";
        case "deprecated": return "deprecated";
        case "authors": return "authors";
        case "bugs": return "bugs";
        case "date": return "date";
        case "history": return "history";
        case "license": return "license";
        case "standards": return "standards";
        case "version": return "version";
        case "copyright": return "copyright";
        default: return null;
    }
}

private string headingCase(string name) @safe pure
{
    import std.array : replace;

    return name.replace('_', ' ');
}

private void appendBlock(ref OutBuffer buf, scope const(char)[] block)
{
    if (buf.length)
        buf.writestring("\n\n");
    buf.writestring(block);
}

// -- macro expansion ---------------------------------------------------------

private void expandWith(ref MacroTable table, ref OutBuffer buf) @system
{
    size_t end = buf.length;
    table.expand(buf, 0, end, null, global.recursionLimit, &isIdStart, &isIdTail);
}

/// The markdown-emitting macro table: DMD's engine emits these names; they
/// expand to CommonMark instead of the HTML theme. Plus the dlang.org shim
/// vocabulary (not compiler builtins, but ubiquitous in real-world docs).
private void defineMacros(ref MacroTable t) @safe pure nothrow
{
    // --- structure wrappers the engine emits around processed text
    foreach (passthrough; ["DDOC_SUMMARY", "DDOC_DESCRIPTION", "DDOC_SECTION",
        "DDOC_SECTIONS", "DDOC_EXAMPLES", "DDOC_AUTO_PSYMBOL_SUPPRESS",
        "DEPRECATED", "ARGS", "TT", "P"])
        t.define(passthrough, "$0");
    t.define("DDOC_SECTION_H", "**$0:**");
    t.define("DDOC_COMMENT", "");
    t.define("DDOC_BLANKLINE", "\n\n");
    t.define("DDOC_ANCHOR", "");

    // --- Params: recovery (see renderDdocText)
    t.define("DDOC_PARAMS", "$0");
    t.define("DDOC_PARAM_ROW", "$0\x03");
    t.define("DDOC_PARAM_ID", "$0\x02");
    t.define("DDOC_PARAM_DESC", "$0");

    // --- inline code / auto-emphasis
    foreach (code; ["DDOC_BACKQUOTED", "D_INLINECODE", "DDOC_PARAM",
        "DDOC_PSYMBOL", "DDOC_PSUPER_SYMBOL", "DDOC_KEYWORD",
        "DDOC_AUTO_PSYMBOL", "DDOC_AUTO_KEYWORD", "DDOC_AUTO_PARAM", "D"])
        t.define(code, "`$0`");

    // --- code blocks: fence content passes through raw (token-highlight
    // macros inside must not inject markup into a fence).
    t.define("D_CODE", "\n```d\n$0\n```\n");
    t.define("OTHER_CODE", "\n```$1\n$+\n```\n");
    foreach (tok; ["D_COMMENT", "D_STRING", "D_KEYWORD", "D_PSYMBOL", "D_PARAM"])
        t.define(tok, "$0");

    // --- markdown re-emission (the engine parsed source markdown into these)
    t.define("EM", "*$0*");
    t.define("I", "*$0*");
    t.define("STRONG", "**$0**");
    t.define("B", "**$0**");
    t.define("U", "$0");
    foreach (i, h; ["H1", "H2", "H3", "H4", "H5", "H6"])
    {
        // "# ", "## ", ... — build statically to stay pure.
        static immutable prefixes = ["# ", "## ", "### ", "#### ", "##### ", "###### "];
        t.define(h, "\n" ~ prefixes[i] ~ "$0\n");
    }
    t.define("HR", "\n---\n");
    t.define("BLOCKQUOTE", "\n> $0\n");
    t.define("LINK", "[$0]($0)");
    t.define("LINK2", "[$+]($1)");
    t.define("LINK_TITLE", "[$3]($1)");
    t.define("DDOC_LINK_AUTODETECT", "$0");
    t.define("IMAGE", "![$+]($1)");
    t.define("IMAGE_TITLE", "![$3]($1)");
    t.define("SYMBOL_LINK", "[$+]($1)");

    // --- lists / tables: emit markdown line-wise
    t.define("UL", "\n$0\n");
    t.define("OL", "\n$0\n");
    t.define("OL_START", "\n$2\n");
    t.define("LI", "- $0\n");
    t.define("TABLE", "\n$0\n");
    t.define("THEAD", "$0");
    t.define("TBODY", "$0");
    t.define("TR", "|$0\n");
    t.define("TH", " $0 |");
    t.define("TD", " $0 |");
    t.define("TH_ALIGN", " $+ |");
    t.define("TD_ALIGN", " $+ |");
    t.define("DL", "\n$0\n");
    t.define("DT", "\n**$0**\n");
    t.define("DD", "\n: $0\n");

    // --- literals
    t.define("LPAREN", "(");
    t.define("RPAREN", ")");
    t.define("COMMA", ",");
    t.define("DOLLAR", "$");
    t.define("BACKTICK", "`");
    t.define("LF", "\n");
    t.define("NBSP", " ");
    t.define("BR", "\n");
    t.define("AMP", "&");
    t.define("LT", "<");
    t.define("GT", ">");

    // --- presentational passthroughs
    foreach (color; ["RED", "BLUE", "GREEN", "YELLOW", "BLACK", "WHITE",
        "BIG", "SMALL"])
        t.define(color, "$0");

    // --- dlang.org shim vocabulary (never let real-world docs go blank)
    t.define("LREF", "`$0`");
    t.define("MREF", "`$0`");
    t.define("REF", "`$1`");
    t.define("REF1", "`$1`");
    t.define("MREF_ALTTEXT", "$1");
    t.define("LREF_ALTTEXT", "$1");
    t.define("HTTP", "[$+](http://$1)");
    t.define("HTTPS", "[$+](https://$1)");
    t.define("WEB", "[$+](https://$1)");
    t.define("BIGOH", "O($0)");
    t.define("PHOBOSSRC", "`$0`");
    t.define("DRUNTIMESRC", "`$0`");
    t.define("GLOSSARY", "$0");
    t.define("XREF", "`$2`");
    t.define("CXREF", "`$2`");
    t.define("DDSUBLINK", "$3");
    t.define("RELATIVE_LINK2", "$+");
    t.define("LNAME2", "$+");

    // --- last resort: an unknown macro renders its arguments (dmd's
    // default deletes the whole invocation — catastrophic for tooltips).
    // Its argument text is "NAME,original args": keep only the args.
    t.define("DDOC_UNDEFINED_MACRO", "$+");
}

// -- post-processing ---------------------------------------------------------

/// Collapses the engine's spacing artifacts into tidy CommonMark: CRs
/// dropped, 3+ blank lines folded to one blank line, trailing per-line
/// whitespace trimmed.
private string cleanupMarkdown(string s) @safe pure
{
    import std.algorithm.iteration : map, splitter;
    import std.array : array, join;
    import std.string : stripRight;

    s = stripSentinels(s);
    auto lines = s.splitter('\n').map!(l => l.stripRight("\r").stripRight).array;
    // Fold runs of blank lines; drop the blank between consecutive list
    // items (the LI macro's newlines would render every list loose) and the
    // blank a code-block macro leaves before its closing fence.
    import std.algorithm.searching : startsWith;

    string[] folded;
    bool prevBlank = false;
    foreach (i, l; lines)
    {
        const blank = l.length == 0;
        if (blank && prevBlank)
            continue;
        if (blank && i + 1 < lines.length && folded.length
            && folded[$ - 1].startsWith("- ") && lines[i + 1].startsWith("- "))
            continue;
        if (blank && i + 1 < lines.length && lines[i + 1].startsWith("```"))
            continue;
        folded ~= l;
        prevBlank = blank;
    }
    return folded.join("\n");
}

/// Removes the macro expander's 0xFF escape sentinels — each 0xFF and the
/// byte after it — exactly as `gendocfile`'s output pass does.
private string stripSentinels(string s) @safe pure nothrow
{
    auto o = new char[](0);
    o.reserve(s.length);
    for (size_t i = 0; i < s.length; i++)
    {
        if (s[i] == '\xFF' && i + 1 < s.length)
        {
            i++;
            continue;
        }
        o ~= s[i];
    }
    import std.exception : assumeUnique;

    return () @trusted { return cast(string) o; }();
}

/// The declared parameter's bare name: `DDOC_PARAM_ID` renders the whole
/// declarator (`int \`x\``, `scope const(char)[] name`, …); the identifier is
/// its last word, backticks shed.
private string bareParamName(const(char)[] id) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.string : strip;

    string last;
    foreach (word; id.strip.splitter(' '))
        if (word.length)
            last = word.idup;
    while (last.length && (last[0] == '`' || last[0] == '*'))
        last = last[1 .. $];
    while (last.length && (last[$ - 1] == '`' || last[$ - 1] == '.'))
        last = last[0 .. $ - 1];
    return last;
}

/// Joins `Params:` continuation lines: any whitespace run becomes one space.
private string collapseWhitespace(const(char)[] s) @safe pure
{
    import std.algorithm.iteration : filter, joiner, map, splitter;
    import std.conv : to;
    import std.string : strip;

    string outp;
    foreach (word; s.splitter!(c => c == ' ' || c == '\n' || c == '\t'))
    {
        if (!word.length)
            continue;
        if (outp.length)
            outp ~= " ";
        outp ~= word;
    }
    return outp;
}

private ptrdiff_t indexOfCtl(scope const(char)[] s, char ctl) @safe pure nothrow @nogc
{
    foreach (i, c; s)
        if (c == ctl)
            return i;
    return -1;
}

private const(char)[][] splitCtl(scope const(char)[] s, char ctl) @safe pure
{
    const(char)[][] parts;
    size_t start = 0;
    foreach (i, c; s)
        if (c == ctl)
        {
            parts ~= s[start .. i].idup;
            start = i + 1;
        }
    return parts;
}

// -- tests -------------------------------------------------------------------
// Env-gated (the engine runs inside a live analysis session); each mirrors
// rows of the DDC matrix in docs/specs/dmd-lsp/ddoc.md.

version (unittest)
{
    import sparkles.dmd_lsp.api : Tip;
    import sparkles.dmd_lsp.testing : withAnalysis;

    /// Analyzes `module test;` + `source` and returns the tip at 1-based
    /// `line`/`col` of the concatenation (line 1 is the module declaration).
    private Tip tipIn(string source, uint line, uint col) @system
    {
        Tip tip;
        withAnalysis("module test;\n" ~ source, (m) {
            tip = m.tipAt(line, col);
        });
        return tip;
    }
}

@("ddoc.render.summaryDescriptionSections")
@system unittest
{
    const tip = tipIn("/**\n"                     // line 2
        ~ "Summary sentence.\n"
        ~ "\n"
        ~ "Description paragraph.\n"
        ~ "\n"
        ~ "Returns: the answer.\n"
        ~ "Throws: never.\n"
        ~ "See_Also: something else\n"
        ~ "Deprecated: use `other`.\n"
        ~ "*/\n"
        ~ "int f() => 1;\n", 12, 5);              // `f` on line 12
    assert(tip.doc == "Summary sentence.\n\nDescription paragraph.", tip.doc);
    assert(tip.tags == [
        ["returns", "the answer."],
        ["throws", "never."],
        ["see", "something else"],
        ["deprecated", "use `other`."],
    ], tip.tags.toDebugString);
}

@("ddoc.render.paramsRows")
@system unittest
{
    const tip = tipIn("/**\n"
        ~ "Sums.\n"
        ~ "Params:\n"
        ~ "    x = the first,\n"
        ~ "        continued on the next line\n"
        ~ "    y = the second\n"
        ~ "*/\n"
        ~ "int add(int x, int y) => x + y;\n", 9, 5);
    assert(tip.tags == [
        ["param", "x the first, continued on the next line"],
        ["param", "y the second"],
    ], tip.tags.toDebugString);

    // paramDocFor resolves one row (the per-param hover path).
    const r = DdocRendered(tags: [["param", "x the first"], ["param", "y two"]]);
    assert(paramDocFor(r, "x") == "the first");
    assert(paramDocFor(r, "y") == "two");
    assert(paramDocFor(r, "z") is null);
}

@("ddoc.render.macros")
@system unittest
{
    const tip = tipIn("/**\n"
        ~ "$(B bold) and $(I italic) and $(WRAP wrapped) and\n"
        ~ "$(UNKNOWN_MACRO args survive) and \\$(LITERAL).\n"
        ~ "\n"
        ~ "Macros:\n"
        ~ "    WRAP = [[$0]]\n"
        ~ "*/\n"
        ~ "int m;\n", 9, 5);
    assert(tip.doc == "**bold** and *italic* and [[wrapped]] and\n"
        ~ "args survive and $(LITERAL).", tip.doc);
}

@("ddoc.render.markdownAndFences")
@system unittest
{
    const tip = tipIn("/**\n"
        ~ "# Heading\n"
        ~ "\n"
        ~ "- one\n"
        ~ "- two\n"
        ~ "\n"
        // NB: a line-leading `*` would be stripped as /** */ margin (the
        // spec's doubling caveat), so the emphasis sits mid-line.
        ~ "with *em* and **strong** and snake_case_name stays.\n"
        ~ "\n"
        ~ "---\n"
        ~ "auto x = 1;\n"
        ~ "---\n"
        ~ "*/\n"
        ~ "int k;\n", 14, 5);
    assert(tip.doc == "# Heading\n\n- one\n- two\n\n"
        ~ "with *em* and **strong** and snake_case_name stays.\n\n"
        ~ "```d\nauto x = 1;\n```", tip.doc);
}

@("ddoc.render.dlangShims")
@system unittest
{
    // The dlang.org vocabulary is not predefined in the compiler; without
    // the shim table every one of these would silently vanish (the
    // undefined-macro default) — the single worst tooltip failure mode.
    const tip = tipIn("/**\n"
        ~ "See $(REF map, std,algorithm), $(LREF local), $(D int[]),\n"
        ~ "$(HTTP dlang.org, the site), runs in $(BIGOH n log n).\n"
        ~ "*/\n"
        ~ "int s;\n", 6, 5);
    assert(tip.doc == "See `map`, `local`, `int[]`,\n"
        ~ "[the site](http://dlang.org), runs in O(n log n).", tip.doc);
}

@("ddoc.render.autoEmphasisAndSuppression")
@system unittest
{
    // Parameters referenced in prose auto-emphasize as code; `_x` suppresses
    // and sheds the underscore.
    const tip = tipIn("/**\n"
        ~ "Uses x and also _y literally. Returns null sometimes.\n"
        ~ "*/\n"
        ~ "int* g(int x, int y) => null;\n", 5, 6);
    assert(tip.doc == "Uses `x` and also y literally. Returns `null` sometimes.",
        tip.doc);
}

version (unittest)
private string toDebugString(in string[][] tags) @safe pure
{
    import std.conv : to;

    return tags.to!string;
}

@("ddoc.render.parameterHoverDocs")
@system unittest
{
    import sparkles.dmd_lsp.testing : withAnalysis;

    // Hovering a parameter usage inherits its Params: row from the enclosing
    // function (the 08-jsdoc reference shape): docs = the row's description,
    // tags = only that parameter's chip.
    withAnalysis("module test;\n"
        ~ "/**\n"
        ~ "Scales.\n"
        ~ "Params:\n"
        ~ "    factor = the multiplier applied to `value`\n"
        ~ "    value = the input\n"
        ~ "*/\n"
        ~ "int scale(int factor, int value) => factor * value;\n", (m) {
        const tip = m.tipAt(8, 40); // `factor` in the body expression
        assert(tip.kind == "parameter", tip.kind);
        // ``value``: the engine auto-emphasizes the parameter name inside the
        // author's own backticks — a double-backtick code span, which is
        // valid CommonMark and renders identically to `value`.
        assert(tip.doc == "the multiplier applied to ``value``", tip.doc);
        assert(tip.tags == [["param",
            "factor the multiplier applied to ``value``"]], tip.tags.toDebugString);
    });
}
