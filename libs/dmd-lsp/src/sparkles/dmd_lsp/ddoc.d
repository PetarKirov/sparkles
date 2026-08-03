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
import dmd.location : Loc;
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

/// Brackets the `MREF` recovery macro emits around a module path, so
/// `joinModulePaths` can splice `std, algorithm` back into `std.algorithm`
/// (the macro engine has no way to join its arguments).
private enum char pathOpen = '\x05';
private enum char pathClose = '\x06';

/// List framing the `UL`/`OL`/`OL_START` macros emit, so `renumberLists` can
/// tell an ordered item from an unordered one: `LI` is shared between both and
/// a macro cannot see its parent. Each marker sits on a line of its own;
/// `olOpen`'s line carries the start index. Both kinds close with `listClose`.
private enum char ulOpen = '\x0E';
private enum char olOpen = '\x0F';
private enum char listClose = '\x11';

/// Table framing: each header cell records its column's alignment between
/// `alignOpen`/`alignClose`. That both marks the row as a header — the
/// delimiter row CommonMark requires is absent from DDoc's output, and
/// dlang.org's `BOOKTABLE` has no `THEAD` to hang it off — and says whether
/// the column wanted `:-`, `-:` or `:-:`.
private enum char alignOpen = '\x13';
private enum char alignClose = '\x14';

/// Marks the fence on the line after it as coming from a documented unittest.
/// The engine keeps only the first word of a fence's info string (`d`), so the
/// label cannot be written into the fence directly; `reflowListsAndTables`
/// moves it back on.
private enum char runnableMark = '\x15';

/// Drops the source indentation a captured unittest body carries — it is the
/// declaration's position in the file, not the example's own shape. Without
/// this the first line lands flush and every other keeps its original column.
private string dedent(const(char)[] code) @safe pure
{
    import std.algorithm.iteration : map, splitter;
    import std.array : array, join;
    import std.string : stripRight;

    auto lines = code.splitter('\n').map!(l => l.stripRight).array;
    size_t common = size_t.max;
    foreach (l; lines)
    {
        if (!l.length)
            continue;
        size_t i = 0;
        while (i < l.length && l[i] == ' ')
            ++i;
        if (i < common)
            common = i;
    }
    if (common == size_t.max)
        common = 0;

    string[] outLines;
    foreach (l; lines)
        outLines ~= (l.length > common ? l[common .. $] : "").idup;
    // Trim the blank lines the braces leave at either end.
    size_t lo = 0, hi = outLines.length;
    while (lo < hi && outLines[lo].length == 0)
        ++lo;
    while (hi > lo && outLines[hi - 1].length == 0)
        --hi;
    return outLines[lo .. hi].join("\n");
}

/// Whether a doc comment is nothing but `ditto` — case-insensitive, with
/// whitespace either side (`dmd.doc.isDitto`, which is private to that module).
private bool isDittoComment(const(char)* comment) @system
{
    import core.stdc.string : strlen;
    import std.ascii : toLower;
    import std.string : strip;

    if (comment is null)
        return false;
    const c = comment[0 .. strlen(comment)].strip;
    if (c.length != 5)
        return false;
    foreach (i, ch; c)
        if (ch.toLower != "ditto"[i])
            return false;
    return true;
}

/**
The `Examples:` section a symbol's documented unittests contribute (`DDC15`).

The parser hangs each `/// …` unittest off the declaration above it and keeps
its body text; the merge into an `Examples:` section is `emitComment`'s job,
which only runs while writing a documentation file, so tooltips never saw
them. Appending the section to the comment text lets the ordinary section
machinery render it — heading, prose and fenced code alike.

Requires `-unittest`: without it the parser skips unittest bodies wholesale,
so there is nothing to attach. Private ones are omitted, as upstream does.
*/
private string documentedUnittests(Dsymbol sym) @system
{
    import core.stdc.string : strlen;
    import std.string : strip;

    import dmd.dsymbol : Visibility;
    import dmd.func : UnitTestDeclaration;

    if (sym is null)
        return null;

    string body_;
    for (UnitTestDeclaration utd = sym.ddocUnittest; utd !is null; utd = utd.ddocUnittest)
    {
        if (utd.visibility.kind == Visibility.Kind.private_
            || utd.comment is null || utd.fbody is null)
            continue;
        // `/// ditto` on a unittest means "another example for the same
        // declaration", not prose — the idiom exists precisely so a second
        // example needs no second write-up. Emitting the word would put the
        // literal "ditto" above the code.
        const prose = isDittoComment(utd.comment)
            ? null : utd.comment[0 .. strlen(utd.comment)].strip;
        if (prose.length)
            body_ ~= "\n" ~ prose ~ "\n";
        if (utd.codedoc !is null)
        {
            const code = dedent(utd.codedoc[0 .. strlen(utd.codedoc)]);
            if (code.length)
                body_ ~= "\n" ~ runnableMark ~ "\n```d\n" ~ code ~ "\n```\n";
        }
    }
    return body_.length ? "\n\nExamples:\n" ~ body_ : null;
}

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

    comment ~= documentedUnittests(sym);

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

    const loc = renderLoc(sym);
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
            if (!loc.isValid)
                continue; // see renderLoc: the row parser highlights too

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
            if (loc.isValid)
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

    import std.algorithm.searching : endsWith;
    import std.string : strip;

    result.docs = docs[].idup.strip;
    // A closing fence needs its newline: `strip` would leave the document
    // ending on the fence marker itself, which the markdown parser then reads
    // as part of the code rather than the end of it — the stray ``` that
    // showed up inside `core.time.Duration`'s Examples block.
    if (result.docs.endsWith("```"))
        result.docs ~= "\n";
    return result;
}

/**
The location `highlightText`/`ParamSection.write` may be handed.

Both begin by advancing the location one line, which indexes DMD's global
source-location table; an unset `Loc` (index 0) walks off the front of that
table and kills the process. A $(B module)'s own `loc` is unset — the
module-level doc comment, the one Phobos-style modules always carry, is
exactly the case that hits this — so borrow the first member's location. It is
only used to attribute a line number to a ddoc warning, so a nearby location
costs nothing and an invalid one costs the process.

Returns `Loc.initial` when nothing valid exists; callers must then skip the
highlight pass rather than pass it on.
*/
private Loc renderLoc(Dsymbol sym) @system
{
    if (sym.loc.isValid)
        return sym.loc;

    auto mod = sym.getModule();
    if (mod is null)
        return Loc.initial;
    if (mod.loc.isValid)
        return mod.loc;
    if (mod.members !is null)
        foreach (member; *mod.members)
            if (member !is null && member.loc.isValid)
                return member.loc;
    return Loc.initial;
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
    //
    // `LI` is shared by both list kinds, so the framing macros bracket their
    // items and `renumberLists` rewrites the marker afterwards. `OL_START`
    // carries the author's start index as `$1` (`ddoc.dd`'s `$(OL_START n,…)`).
    t.define("UL", "\n" ~ ulOpen ~ "\n$0\n" ~ listClose ~ "\n");
    t.define("OL", "\n" ~ olOpen ~ "1\n$0\n" ~ listClose ~ "\n");
    t.define("OL_START", "\n" ~ olOpen ~ "$1\n$+\n" ~ listClose ~ "\n");
    t.define("LI", "- $0\n");
    t.define("TABLE", "\n$0\n");
    // The engine puts no newline between `$(THEAD …)` and `$(TBODY …)`, and
    // `TR` no longer supplies one, so the header row would run into the first
    // body row.
    t.define("THEAD", "$0\n");
    t.define("TBODY", "$0");
    // No trailing newline: the engine already separates rows, and a second one
    // makes every row its own paragraph, which ends the table at row one.
    t.define("TR", "|$0");
    // Every header cell records an alignment, `-` meaning none, so the
    // delimiter row can be built positionally.
    t.define("TH", " $0 |" ~ alignOpen ~ "-" ~ alignClose);
    t.define("TD", " $0 |");
    t.define("TH_ALIGN", " $+ |" ~ alignOpen ~ "$1" ~ alignClose);
    t.define("TD_ALIGN", " $+ |");
    // dlang.org's no-wrap cells, used by every Phobos module summary table.
    t.define("TDNW", " $0 |");
    t.define("THNW", " $0 |");
    t.define("TDNW2", " $0 |");
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
    // A module path, one package per argument: marked for `joinModulePaths`,
    // since a macro body cannot join `std, algorithm` into `std.algorithm`.
    t.define("MREF", pathOpen ~ "$0" ~ pathClose);
    t.define("REF", "`$1`");
    t.define("REF1", "`$1`");
    t.define("MREF_ALTTEXT", "$1");
    t.define("LREF_ALTTEXT", "$1");
    t.define("REF_ALTTEXT", "$1");

    // Page furniture that carries no documentation: dlang.org's quick-index
    // script, its wrapper div, and the summary table's caption argument.
    // Left undefined these dump JavaScript and a CSS class name into the
    // first line of every Phobos module tooltip.
    t.define("SCRIPT", "");
    t.define("DIVC", "$+");
    t.define("DIVID", "$+");
    t.define("BOOKTABLE", "\n$+\n");
    t.define("T2", "| $1 | $+ |\n");
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
    import std.algorithm.searching : startsWith;
    import std.array : array, join;
    import std.string : stripLeft, stripRight;

    s = joinModulePaths(stripSentinels(s));
    auto lines = reflowListsAndTables(
        s.splitter('\n').map!(l => l.stripRight("\r").stripRight.idup).array);

    // Fold runs of blank lines; drop the blank between consecutive list
    // items (the LI macro's newlines would render every list loose) and the
    // blank a code-block macro leaves before its closing fence.
    string[] folded;
    bool prevBlank = false;
    foreach (i, l; lines)
    {
        const blank = l.length == 0;
        if (blank && prevBlank)
            continue;
        // Keep a list tight. The next line is often another blank (a nested
        // list's framing left two), so look past them — otherwise every
        // numbered list renders loose, one paragraph per item.
        if (blank && folded.length && isListItem(folded[$ - 1]))
        {
            size_t j = i + 1;
            while (j < lines.length && lines[j].length == 0)
                ++j;
            if (j < lines.length && isListItem(lines[j]))
                continue;
        }
        if (blank && i + 1 < lines.length && lines[i + 1].startsWith("```"))
            continue;
        folded ~= l;
        prevBlank = blank;
    }
    return folded.join("\n");
}

/// `n` levels of list indentation. Four spaces per level clears the content
/// column of every marker DDoc can produce, so a nested list nests.
private string indentOf(size_t n) @safe pure nothrow
{
    static immutable string spaces = "                                ";
    const w = n * 4;
    if (w <= spaces.length)
        return spaces[0 .. w];
    auto pad = new char[](w);
    pad[] = ' ';
    return () @trusted { return cast(string) pad; }();
}

/// Whether a line opens a list item — `- ` or `12. `. The blank-line fold uses
/// it to keep a list tight; without the ordered form every numbered list
/// rendered loose, one paragraph per item.
private bool isListItem(scope const(char)[] line) @safe pure nothrow @nogc
{
    import std.ascii : isDigit;

    size_t i = 0;
    while (i < line.length && line[i] == ' ')
        ++i;
    if (i + 1 < line.length && line[i] == '-' && line[i + 1] == ' ')
        return true;
    const start = i;
    while (i < line.length && line[i].isDigit)
        ++i;
    return i > start && i + 1 < line.length && line[i] == '.' && line[i + 1] == ' ';
}

/**
Turns the list/table framing the macro table emits into real CommonMark.

Two things DDoc's own output cannot express. `LI` serves both list kinds, so
every item arrives as `- ` and an ordered list loses its numbers; the framing
macros bracket their items and the numbers are put back here, honouring the
author's start index and nesting (a bullet list inside a numbered one stays
bulleted). And a DDoc table has no delimiter row at all — without one
CommonMark reads the rows as a paragraph full of pipes — so each header cell
records its column's alignment and the row is built from those.
*/
private string[] reflowListsAndTables(string[] lines) @safe pure
{
    import std.algorithm.searching : endsWith, startsWith;
    import std.string : stripLeft;

    static struct Frame { bool ordered; int next; }

    Frame[] stack;
    string[] out_;
    bool inFence = false;
    bool markNextFence = false;

    foreach (line; lines)
    {
        if (line.length && line[0] == ulOpen)
        {
            stack ~= Frame(false, 0);
            continue;
        }
        if (line.length && line[0] == olOpen)
        {
            stack ~= Frame(true, startIndex(line[1 .. $]));
            continue;
        }
        if (line.length && line[0] == listClose)
        {
            if (stack.length)
                stack = stack[0 .. $ - 1];
            continue;
        }
        // Indentation is decided here, where the list nesting is known.
        // DDoc has no indented-code convention — its code blocks are `---`
        // sections, which reach here already fenced — so leading whitespace
        // outside a list is the author indenting under `/**`, purely
        // cosmetic. CommonMark disagrees: four such spaces after a blank line
        // is an indented code block, which is how `core.time.dur`'s third
        // paragraph turned into an empty box with its text gone.
        if (line.length && line[0] == runnableMark)
        {
            markNextFence = true;
            continue;
        }
        if (line.stripLeft.startsWith("```"))
        {
            inFence = !inFence;
            // An opening fence the producer marked: label it, so the renderer's
            // fence chrome can say the example is an executable unittest.
            if (inFence && markNextFence)
            {
                out_ ~= line ~ " unittest";
                markNextFence = false;
                continue;
            }
            out_ ~= line;
            continue;
        }
        if (inFence)
        {
            out_ ~= line; // the code's own indentation, not the author's
            continue;
        }

        auto body_ = line.stripLeft;
        if (!body_.length)
        {
            out_ ~= line;
            continue;
        }
        if (stack.length == 0)
        {
            out_ ~= body_;
            continue;
        }

        // Inside a list, indentation *is* structure: an item sits at its
        // depth, and anything else belongs to the item above it. Four spaces
        // per level clears the content column of both `- ` and `12. `.
        const depth = stack.length - 1;
        if (body_.startsWith("- "))
        {
            if (stack[$ - 1].ordered)
            {
                import std.conv : text;

                body_ = text(stack[$ - 1].next) ~ ". " ~ body_[2 .. $];
                stack[$ - 1].next++;
            }
            out_ ~= indentOf(depth) ~ body_;
        }
        else
            out_ ~= indentOf(depth + 1) ~ body_;
    }

    // A row carrying alignment markers is a header row: CommonMark needs a
    // delimiter under it or the table is a paragraph full of pipes, and DDoc
    // emits no such line (nor does dlang.org's `BOOKTABLE`, which has no
    // `THEAD` to hang one off). Take the delimiter now, while the markers are
    // still there, and let it ride along with its header.
    auto delims = new string[](out_.length);
    foreach (i, ref o; out_)
    {
        delims[i] = delimiterRow(o);
        o = stripAlignMarks(o);
    }

    // A GFM row is one line, but a `BOOKTABLE` cell routinely holds a stack of
    // `$(D …)` names on separate lines — Phobos module summaries are all like
    // this. Fold a row's continuations back into it, stopping at a blank line
    // so a stray leading `|` cannot swallow the rest of the doc.
    string[] rows;
    for (size_t i = 0; i < out_.length; i++)
    {
        auto l = out_[i];
        const delim = delims[i];
        if (l.startsWith("|") && !l.endsWith("|"))
            while (i + 1 < out_.length && out_[i + 1].length)
            {
                l ~= " " ~ out_[i + 1];
                ++i;
                if (out_[i].endsWith("|"))
                    break;
            }
        rows ~= l;
        if (delim.length)
            rows ~= delim;
    }
    out_ = rows;
    return out_;
}

/// The `$(OL_START n, …)` index, defaulting to 1 for anything unparseable —
/// a list that starts at the wrong number still reads; one that throws does not.
private int startIndex(scope const(char)[] digits) @safe pure nothrow
{
    int n = 0;
    foreach (c; digits)
    {
        if (c < '0' || c > '9')
            return n > 0 ? n : 1;
        n = n * 10 + (c - '0');
    }
    return n > 0 ? n : 1;
}

/// The delimiter row for a header row, one cell per recorded alignment.
/// Empty when the row carries no markers — then it was never a table header.
private string delimiterRow(scope const(char)[] header) @safe pure
{
    string row;
    for (size_t i = 0; i < header.length; i++)
    {
        if (header[i] != alignOpen)
            continue;
        const start = i + 1;
        size_t end = start;
        while (end < header.length && header[end] != alignClose)
            ++end;
        if (end >= header.length)
            break;
        const a = header[start .. end];
        row ~= a == "left" ? "| :--- "
            : a == "right" ? "| ---: "
            : a == "center" ? "| :---: "
            : "| --- ";
        i = end;
    }
    return row.length ? row ~ "|" : null;
}

/// Drops the alignment markers a header row carries, leaving the cell text.
private string stripAlignMarks(string line) @safe pure
{
    import std.algorithm.searching : canFind;

    if (!line.canFind(alignOpen))
        return line;
    string o;
    for (size_t i = 0; i < line.length; i++)
    {
        if (line[i] == alignOpen)
        {
            while (i < line.length && line[i] != alignClose)
                ++i;
            continue;
        }
        o ~= line[i];
    }
    return o;
}

/// Removes the macro expander's 0xFF escape sentinels — each 0xFF and the
/// byte after it — exactly as `gendocfile`'s output pass does.
/**
Rewrites each `MREF`-marked span into a dotted module path in code ticks:
`$(MREF std, algorithm, iteration)` reaches here as the argument list
`std, algorithm, iteration` between `pathOpen`/`pathClose` and leaves as
`` `std.algorithm.iteration` ``. Unterminated markers are dropped rather than
shown — a half-expanded macro is never useful text.
*/
private string joinModulePaths(string s) @safe pure
{
    import std.algorithm.iteration : joiner, map, splitter;
    import std.array : appender;
    import std.string : strip;

    if (s.length == 0)
        return s;

    auto o = appender!string;
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] != pathOpen)
        {
            o ~= s[i];
            i++;
            continue;
        }

        size_t end = i + 1;
        while (end < s.length && s[end] != pathClose)
            end++;
        if (end >= s.length)
            break; // unterminated: drop the marker and everything after it

        auto parts = s[i + 1 .. end].splitter(',').map!strip;
        o ~= '`';
        o ~= parts.joiner(".");
        o ~= '`';
        i = end + 1;
    }
    return o[];
}

@("dmd_lsp.ddoc.cleanupMarkdown.unindentsProseKeepsCode")
@safe pure unittest
{
    // The `core.time.dur` shape: a continuation paragraph indented under
    // `/**`. Left alone, CommonMark reads it as an indented code block and the
    // tooltip shows an empty box instead of the text.
    assert(cleanupMarkdown("Summary.\n\n    The possible values are:")
        == "Summary.\n\nThe possible values are:");

    // Inside a fence the indentation is the code's own and must survive.
    assert(cleanupMarkdown("```d\n    auto x = 1;\n```")
        == "```d\n    auto x = 1;\n```");
}

@("dmd_lsp.ddoc.joinModulePaths")
@safe pure unittest
{
    assert(joinModulePaths("see " ~ pathOpen ~ "std, algorithm" ~ pathClose ~ ".")
        == "see `std.algorithm`.");
    assert(joinModulePaths(pathOpen ~ "std, algorithm, iteration" ~ pathClose)
        == "`std.algorithm.iteration`");
    assert(joinModulePaths("plain text") == "plain text");
    assert(joinModulePaths("half " ~ pathOpen ~ "std, algorithm") == "half ");
}

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

@("ddoc.render.documentedUnittestsBecomeLabelledExamples")
@system unittest
{
    // `DDC15`: the unittest → `Examples:` merge is `emitComment`'s job, which
    // only runs while writing a documentation file. The fence carries a
    // `unittest` label so the renderer's chrome can say the example is
    // executable rather than illustrative.
    import sparkles.dmd_lsp.testing : withAnalysis;
    import std.algorithm.searching : canFind;

    enum src = q{
        module test;
        /// Returns the larger of two.
        int larger(int a, int b) => a >= b ? a : b;   // Line 4

        /// One way to use it.
        unittest
        {
            assert(larger(2, 3) == 3);
        }

        /// ditto
        unittest
        {
            assert(larger(-1, -5) == -1);
        }
    };

    withAnalysis(src, (m) {
        const doc = m.tipAt(4, 13).doc;
        assert(doc.canFind("### Examples"), doc);
        assert(doc.canFind("One way to use it."), doc);
        // Two labelled fences, one per documented unittest.
        assert(doc.canFind("```d unittest\nassert(larger(2, 3) == 3);\n```"), doc);
        assert(doc.canFind("```d unittest\nassert(larger(-1, -5) == -1);\n```"), doc);
        // `/// ditto` on a unittest means "another example", not prose.
        assert(!doc.canFind("ditto"), doc);
    }, null, ["-unittest"]);
}

@("ddoc.render.tablesGetTheirDelimiterRow")
@system unittest
{
    // DDoc's own table output has no delimiter row, and CommonMark without one
    // reads the whole thing as a paragraph full of pipes. The alignment DDoc
    // recorded per column has to survive with it.
    const tip = tipIn("/**\n"
        ~ "| L | C | R |\n"
        ~ "| :- | :-: | -: |\n"
        ~ "| a | b | c |\n"
        ~ "| d | e | f |\n"
        ~ "*/\n"
        ~ "int k;\n", 8, 5);
    assert(tip.doc == "| L | C | R |\n"
        ~ "| :--- | :---: | ---: |\n"
        ~ "| a | b | c |\n"
        ~ "| d | e | f |", tip.doc);
}

@("ddoc.render.orderedListsKeepTheirNumbers")
@system unittest
{
    // `LI` serves both list kinds, so every item arrives as `- `; the numbers
    // are put back from the list framing, including the author's start index.
    // A bullet list nested in a numbered one stays bulleted.
    const tip = tipIn("/**\n"
        ~ "3. third\n"
        ~ "4. fourth\n"
        ~ "\n"
        ~ "1. outer\n"
        ~ "    - inner\n"
        ~ "2. second\n"
        ~ "*/\n"
        ~ "int k;\n", 10, 5);
    assert(tip.doc == "3. third\n4. fourth\n\n"
        ~ "1. outer\n    - inner\n2. second", tip.doc);
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
    // The trailing newline after the closing fence is deliberate: without it
    // a markdown parser reads the fence marker as part of the code.
    assert(tip.doc == "# Heading\n\n- one\n- two\n\n"
        ~ "with *em* and **strong** and snake_case_name stays.\n\n"
        ~ "```d\nauto x = 1;\n```\n", tip.doc);
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
