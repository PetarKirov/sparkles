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

import std.array : replicate;
import std.conv : text;

import dmd.common.outbuffer : OutBuffer;
import dmd.dmacro : MacroTable;
import dmd.doc : DocComment, escapetable, highlightText, isIdStart, isIdTail,
    ParamSection, Section;
import dmd.dscope : Scope;
import dmd.dsymbol : Dsymbol;
import dmd.dsymbolsem : scopeCreateGlobal;
import dmd.globals : global;
import dmd.location : Loc;

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
    import std.algorithm.comparison : min;
    import std.algorithm.iteration : filter, fold, map, splitter;
    import std.array : array, join;
    import std.string : stripLeft, stripRight;

    auto lines = code.splitter('\n').map!(l => l.stripRight).array;

    // The common indent, ignoring blank lines — they carry none to speak of.
    // An all-blank body folds to `size_t.max`, which the slice below reads as
    // "nothing to keep", which is the right answer for it.
    const common = lines.filter!(l => l.length > 0)
        .map!(l => l.length - l.stripLeft(" ").length)
        .fold!min(size_t.max);

    // The braces leave a blank line at either end.
    return lines.map!(l => l.length > common ? l[common .. $] : l[0 .. 0])
        .array
        .strippedOfBlankEnds
        .map!(l => l.idup)
        .join("\n");
}

/// The slice with leading and trailing blank lines dropped. `std.string.strip`
/// works on characters; this is the line-wise twin the same idea needs.
private inout(T)[] strippedOfBlankEnds(T)(inout(T)[] lines)
{
    size_t lo = 0, hi = lines.length;
    while (lo < hi && lines[lo].length == 0)
        ++lo;
    while (hi > lo && lines[hi - 1].length == 0)
        --hi;
    return lines[lo .. hi];
}


/// Whether a doc comment is nothing but `ditto` — case-insensitive, with
/// whitespace either side. `dmd.doc.isDitto` is private to that module, and
/// the rule is frozen by `DDC11`, so it is restated here rather than patched
/// into the fork. Shared with `visitor.dittoTarget`, which resolves what such
/// a comment points at.
package bool isDittoComment(const(char)* comment) @system
{
    import core.stdc.string : strlen;
    import std.string : strip;
    import std.uni : icmp;

    return comment !is null
        && icmp(comment[0 .. strlen(comment)].strip, "ditto") == 0;
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

    // The chain hangs off whichever declaration the unittest followed in
    // source. For a call site that is rarely the symbol we resolved to:
    // `each!(int[])` is an instance of the inner eponymous `each(Iterable)`,
    // which is a member of the outer `template each(alias pred)` — and it is
    // the outer one the `/// …` unittest came after. Climb the template links
    // the same way `docForSymbol` does, bounded for the same reason.
    enum maxHops = 8;
    auto owner = sym;
    foreach (_; 0 .. maxHops)
    {
        if (owner.ddocUnittest !is null || owner.parent is null)
            break;
        if (auto td = owner.parent.isTemplateDeclaration())
        {
            owner = td;
            continue;
        }
        if (auto ti = owner.parent.isTemplateInstance())
        {
            auto td = ti.tempdecl !is null ? ti.tempdecl.isTemplateDeclaration() : null;
            owner = td !is null ? cast(Dsymbol) td : cast(Dsymbol) ti;
            continue;
        }
        break;
    }

    string body_;
    for (UnitTestDeclaration utd = owner.ddocUnittest; utd !is null; utd = utd.ddocUnittest)
    {
        // No `fbody` check: outside the root module the fork records the body
        // *text* without parsing it (no AST, no semantic), which is all an
        // `Examples:` section needs — and is the only way a Phobos hover has
        // examples at all.
        if (utd.visibility.kind == Visibility.Kind.private_
            || utd.comment is null || utd.codedoc is null)
            continue;
        // `/// ditto` on a unittest means "another example for the same
        // declaration", not prose — the idiom exists precisely so a second
        // example needs no second write-up. Emitting the word would put the
        // literal "ditto" above the code.
        const prose = isDittoComment(utd.comment)
            ? null : utd.comment[0 .. strlen(utd.comment)].strip;
        if (prose.length)
            body_ ~= i"\n$(prose)\n".text;
        if (utd.codedoc !is null)
        {
            const code = dedent(utd.codedoc[0 .. strlen(utd.codedoc)]);
            if (code.length)
                body_ ~= i"\n$(runnableMark)\n```d\n$(code)\n```\n".text;
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
            import std.algorithm.iteration : splitter;
            import std.string : indexOf;

            // `splitter` drops the trailing empty field the final separator
            // leaves; the `indexOf < 0` guard below skips it either way.
            foreach (row; stripSentinels(rows[].idup).splitter(rowSep))
            {
                const at = row.indexOf(idSep);
                if (at < 0)
                    continue;

                const id = bareParamName(row[0 .. at]);
                const desc = collapseWhitespace(row[at + 1 .. $]);
                if (!id.length)
                    continue;
                result.tags ~= ["param", desc.length ? i"$(id) $(desc)".text : id];
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
    // `$0` already ends with the block's own newline, so the fence follows it
    // directly — a second one would put a blank line inside the code, which
    // `DDC31` says is the author's to place, not ours.
    t.define("D_CODE", "\n```d\n$0```\n");
    t.define("OTHER_CODE", "\n```$1\n$+```\n");
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
    // dlang.org's `<pre>`: line structure and indentation are the content —
    // Phobos writes the `std.conv.to` grammars with it. Undefined, it fell
    // through to `DDOC_UNDEFINED_MACRO` and dissolved into one prose line.
    t.define("PRE", "\n```\n$0\n```\n");
    t.define("HR", "\n---\n");
    t.define("BLOCKQUOTE", "\n> $0\n");
    t.define("LINK", "[$0]($0)");
    t.define("LINK2", "[$+]($1)");
    t.define("LINK_TITLE", "[$3]($1)");
    t.define("DDOC_LINK_AUTODETECT", "$0");
    t.define("IMAGE", "![$+]($1)");
    t.define("IMAGE_TITLE", "![$3]($1)");
    // A `[Symbol]` reference resolves to a *dlang.org* URL (`object.html#.Object`),
    // which is a dead link anywhere else — and a tooltip is anywhere else. The
    // name is what the reader wanted; render it as code and drop the target.
    t.define("SYMBOL_LINK", "`$+`");

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
    // Only the line ending is normalized here: trailing whitespace is content
    // inside a fence, and the pass below is the one that knows where fences
    // are (`DDC31`).
    bool[] fenced;
    auto lines = reflowListsAndTables(
        s.splitter('\n').map!(l => l.stripRight("\r").idup).array, fenced);

    // Fold runs of blank lines; drop the blank between consecutive list
    // items (the LI macro's newlines would render every list loose) and the
    // blank a code-block macro leaves before its closing fence.
    string[] folded;
    bool prevBlank = false;
    foreach (i, l; lines)
    {
        // Inside a fence every line is the code's own — a run of blanks and a
        // trailing space are both content, not layout.
        if (fenced[i])
        {
            folded ~= l;
            prevBlank = false;
            continue;
        }
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
        folded ~= l;
        prevBlank = blank;
    }
    return folded.join("\n");
}

/// `n` levels of list indentation. Four spaces per level clears the content
/// column of every marker DDoc can produce, so a nested list nests.
private string indentOf(size_t n) @safe pure => replicate(" ", n * 4);


/// Whether a line opens a list item — `- ` or `12. `. The blank-line fold uses
/// it to keep a list tight; without the ordered form every numbered list
/// rendered loose, one paragraph per item.
private bool isListItem(scope const(char)[] line) @safe pure
{
    import std.algorithm.searching : countUntil, startsWith;
    import std.ascii : isDigit;
    import std.string : stripLeft;

    const body_ = line.stripLeft;
    if (body_.startsWith("- "))
        return true;
    const digits = body_.countUntil!(c => !c.isDigit);
    return digits > 0 && body_[digits .. $].startsWith(". ");
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
private string[] reflowListsAndTables(string[] lines, out bool[] fenced) @safe pure
{
    import std.algorithm.searching : endsWith, startsWith;
    import std.string : stripLeft, stripRight;

    static struct Frame { bool ordered; uint next; }

    Frame[] stack;
    string[] out_;
    bool[] isCode;
    bool inFence = false;
    bool markNextFence = false;

    void emit(string line, bool code)
    {
        out_ ~= line;
        isCode ~= code;
    }

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
                emit(line.stripRight ~ " unittest", false);
                markNextFence = false;
                continue;
            }
            emit(line.stripRight, false);
            continue;
        }
        if (inFence)
        {
            // Verbatim: indentation, trailing spaces and blank runs are all
            // the code's own (`DDC31`).
            emit(line, true);
            continue;
        }

        auto body_ = line.stripLeft.stripRight;
        if (!body_.length)
        {
            emit("", false);
            continue;
        }
        if (stack.length == 0)
        {
            emit(body_, false);
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
                body_ = i"$(stack[$ - 1].next). $(body_[2 .. $])".text;
                stack[$ - 1].next++;
            }
            emit(indentOf(depth) ~ body_, false);
        }
        else
            emit(indentOf(depth + 1) ~ body_, false);
    }

    // A row carrying alignment markers is a header row: CommonMark needs a
    // delimiter under it or the table is a paragraph full of pipes, and DDoc
    // emits no such line (nor does dlang.org's `BOOKTABLE`, which has no
    // `THEAD` to hang one off). Take the delimiter now, while the markers are
    // still there, and let it ride along with its header.
    auto delims = new string[](out_.length);
    foreach (i, ref o; out_)
    {
        if (isCode[i])
            continue; // a `|` row inside a fence is code, not a table
        delims[i] = delimiterRow(o);
        o = stripAlignMarks(o);
    }

    // A GFM row is one line, but a `BOOKTABLE` cell routinely holds a stack of
    // `$(D …)` names on separate lines — Phobos module summaries are all like
    // this. Fold a row's continuations back into it, stopping at a blank line
    // so a stray leading `|` cannot swallow the rest of the doc.
    string[] rows;
    bool[] rowsAreCode;
    for (size_t i = 0; i < out_.length; i++)
    {
        auto l = out_[i];
        const delim = delims[i];
        const code = isCode[i];
        if (!code && l.startsWith("|") && !l.endsWith("|"))
            while (i + 1 < out_.length && out_[i + 1].length && !isCode[i + 1])
            {
                l ~= " " ~ out_[i + 1];
                ++i;
                if (out_[i].endsWith("|"))
                    break;
            }
        rows ~= l;
        rowsAreCode ~= code;
        if (delim.length)
        {
            rows ~= delim;
            rowsAreCode ~= false;
        }
    }
    fenced = rowsAreCode;
    return rows;
}

/// The `$(OL_START n, …)` index, defaulting to 1 for anything unparseable —
/// a list that starts at the wrong number still reads; one that throws does not.
private uint startIndex(const(char)[] digits) @safe pure
{
    import std.conv : ConvException, parse;

    try
    {
        auto rest = digits;
        const n = parse!uint(rest);
        return n > 0 ? n : 1;
    }
    catch (ConvException)
        return 1; // no digits, or an index too large to mean anything
}



/// The delimiter row for a header row, one cell per recorded alignment.
/// Empty when the row carries no markers — then it was never a table header.
/// The alignment word each header cell recorded, in column order. An
/// unterminated marker is dropped rather than guessed at.
private auto alignments(const(char)[] header) @safe pure
{
    import std.algorithm.iteration : filter, map, splitter;
    import std.algorithm.searching : findSplit;
    import std.range : drop;

    // `drop`, not `dropOne`: an empty line splits to an empty range, which
    // `dropOne` asserts on.
    return header.splitter(alignOpen)
        .drop(1)
        .map!(part => part.findSplit([alignClose]))
        .filter!(split => cast(bool) split)
        .map!(split => split[0]);
}

/// The delimiter row for a header row, one cell per recorded alignment.
/// Empty when the row carries no markers — then it was never a table header.
private string delimiterRow(const(char)[] header) @safe pure
{
    import std.algorithm.iteration : joiner, map;
    import std.conv : to;

    const row = header.alignments
        .map!(a => a == "left" ? "| :--- "
            : a == "right" ? "| ---: "
            : a == "center" ? "| :---: "
            : "| --- ")
        .joiner
        .to!string;
    return row.length ? row ~ "|" : null;
}

/// Drops the alignment markers a header row carries, leaving the cell text.
private string stripAlignMarks(string line) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind, findSplitAfter;
    import std.range : drop;

    if (!line.canFind(alignOpen))
        return line;

    auto parts = line.splitter(alignOpen);
    string kept = parts.front;
    foreach (part; parts.drop(1))
        if (auto after = part.findSplitAfter([alignClose]))
            kept ~= after[1];
    return kept;
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

@("ddoc.render.importedSymbolsCarryTheirExamples")
@system unittest
{
    // The parser used to skip unittest bodies outside the root module, so no
    // Phobos hover could ever have an example. The fork records the body text
    // while skipping (no AST, no semantic); the owner of the chain is the
    // declaration the unittest followed — for `each` the *outer* template, two
    // hops above the instance a call site resolves to.
    import sparkles.dmd_lsp.testing : withAnalysis;
    import std.algorithm.searching : canFind;

    enum src = q{
        module test;
        import std.algorithm.iteration : each;
        void main()
        {
            [1, 2, 3].each!(n => n);                  // Line 6
        }
    };

    withAnalysis(src, (m) {
        const doc = m.tipAt(6, 23).doc;
        assert(doc.canFind("### Examples"), doc);
        assert(doc.canFind("```d unittest"), doc);
    }, null, ["-unittest"]);
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

@("ddoc.render.preservesPreformattedBlocks")
@system unittest
{
    // dlang.org's `$(PRE …)` is `<pre>`: the line structure and indentation
    // *are* the content. Undefined, it fell through to the undefined-macro
    // path and its whole body dissolved into one line of prose — which is how
    // `std.conv.to`'s two grammars reached the tooltip.
    import std.algorithm.searching : count;

    static void check(string label, string body_, string want)
    {
        const line = cast(uint)(4 + body_.count('\n'));
        const t = tipIn("/**\n" ~ body_ ~ "*/\nint k;\n", line, 5);
        assert(t.doc == want, label ~ ": " ~ t.doc);
    }

    // NB: the lead-in deliberately has no `Word:` shape — that is a section
    // name (`DDC17`), not prose, and would swallow the block into a heading.
    check("PRE keeps its lines",
        "The grammar is\n$(PRE Integer:\n    Sign UnsignedInteger\n    UnsignedInteger)\n",
        "The grammar is\n\n```\nInteger:\n    Sign UnsignedInteger\n    UnsignedInteger\n```\n");

    // The inner `$(I …)`/`$(B …)` expand before `PRE` wraps them, and a fence
    // cannot carry emphasis — so their markers survive as text. dlang.org
    // renders them italic/bold inside the `<pre>`; pinned as the divergence it
    // is rather than stripped, since undoing them would also eat a literal `*`
    // in someone's grammar.
    check("emphasis inside PRE is literal",
        "$(PRE $(I Integer):\n    $(B +))\n",
        "```\n*Integer*:\n    **+**\n```\n");
}

@("ddoc.render.markdownConstructs")
@system unittest
{
    // `DDC39`, `DDC42`, `DDC44`, `DDC46`, `DDC48`, `DDC49`, `DDC51`, `DDC56`.
    // The engine's markdown subset, none of it previously pinned.
    import std.algorithm.searching : count;

    // The declaration follows the closing `*/`, so its line is derived rather
    // than counted by hand: miscounting yields `Tip.init`, which reads exactly
    // like a rendering failure and cost an hour to see through once.
    static void check(string label, string body_, string want)
    {
        const line = cast(uint)(4 + body_.count('\n'));
        const t = tipIn("/**\n" ~ body_ ~ "*/\nint k;\n", line, 5);
        assert(t.doc == want, label ~ ": " ~ t.doc);
    }

    check("DDC39 heading levels", "## Two\n\n###### Six ###\n", "## Two\n\n###### Six");
    check("DDC42 escaped asterisk", "A \\* literal star.\n", "A * literal star.");
    check("DDC44 inline link", "See [the docs](https://dlang.org) here.\n",
        "See [the docs](https://dlang.org) here.");
    // `DDC46`: a `[Symbol]` reference resolves to a dlang.org URL, which is a
    // dead link in a tooltip — the name renders as code instead.
    check("DDC46 symbol reference", "See [Object] for the root.\n",
        "See `Object` for the root.");
    check("DDC48 bare url", "Visit https://dlang.org now.\n", "Visit https://dlang.org now.");
    check("DDC49 image", "![alt](https://dlang.org/logo.png)\n",
        "![alt](https://dlang.org/logo.png)");
    // `DDC51`: inside `/** */` the first `*` of a line is comment margin, so a
    // single-star bullet loses its marker and must be doubled.
    check("DDC51 single star loses the bullet", " * one\n * two\n", "one\ntwo");
    check("DDC51 doubled star is a bullet", " ** one\n ** two\n", "- one\n- two");
    check("DDC56 blockquote with lazy continuation", "> quoted line\nlazy continuation\n",
        "> quoted line\nlazy continuation");
}

@("ddoc.render.markdownConstructsThatDiverge")
@system unittest
{
    // Pinned as they are, not as the plan wishes: each of these is a real
    // divergence and the assertions say what actually happens, so a fix shows
    // up as a failing test rather than as a silent change.
    import std.algorithm.searching : count;

    static void check(string label, string body_, string want)
    {
        const line = cast(uint)(4 + body_.count('\n'));
        const t = tipIn("/**\n" ~ body_ ~ "*/\nint k;\n", line, 5);
        assert(t.doc == want, label ~ ": " ~ t.doc);
    }

    // `DDC45`: a reference definition is not applied — the link stays literal.
    check("DDC45 reference link unresolved",
        "See [the docs][d] here.\n\n[d]: https://dlang.org\n",
        "See [the docs][d] here.");

    // `DDC53`: block content indented under a list item detaches from it.
    check("DDC53 item continuation detaches",
        "- item\n\n    a paragraph in the item\n",
        "- item\n\na paragraph in the item");

    // `DDC57`: the underscore rule survives; the star form is eaten by the
    // same margin rule as `DDC51` — the leading `*` is comment margin, so
    // `* * *` parses as a bullet list rather than a thematic break.
    check("DDC57 underscore rule", "before\n\n___\n\nafter\n", "before\n\n---\n\nafter");
    check("DDC57 star rule is a bullet", "before\n\n* * *\n\nafter\n",
        "before\n\n-\n        -\n\nafter");
}

@("ddoc.render.sectionNameRulesAndParamRows")
@system unittest
{
    // `DDC17`, `DDC18`, `DDC21`, `DDC25`, `DDC26`.
    //
    // `DDC17` as written ("matched case-insensitively, `returns:` ==
    // `Returns:`") is not what the engine does: `doc.d:484` gates the whole
    // section scan on `isupper(*p)`, so the *first* letter must be uppercase
    // and only the rest is case-insensitive. `ReTurNs:` is a section;
    // `returns:` is prose. Pinned both ways round, because getting this wrong
    // silently moves a `Returns:` chip into the description.
    static void check(string label, string src, uint line, string wantDocs,
        string[][] wantTags = null, uint col = 5)
    {
        const t = tipIn(src, line, col);
        assert(t.doc == wantDocs, label ~ " docs: " ~ t.doc);
        assert(t.tags == wantTags, label ~ " tags");
    }

    check("Returns", "/**\nSummary.\nReturns: the answer.\n*/\nint a;\n", 6,
        "Summary.", [["returns", "the answer."]]);
    check("ReTurNs", "/**\nSummary.\nReTurNs: the answer.\n*/\nint b;\n", 6,
        "Summary.", [["returns", "the answer."]]);
    check("lowercase is prose", "/**\nSummary.\nreturns: the answer.\n*/\nint c;\n",
        6, "Summary.\nreturns: the answer.");

    // `DDC18`: the colon in a URL must not start a section.
    check("url", "/**\nSee https://dlang.org for details.\n*/\nint d;\n", 5,
        "See https://dlang.org for details.");

    // `DDC21`: a non-standard section becomes a heading, underscores as spaces.
    check("custom section",
        "/**\nSummary.\nMy_Own_Section: body text.\n*/\nint e;\n", 6,
        "Summary.\n\n### My Own Section\n\nbody text.");

    // `DDC25`: text before the first `name =` row is dropped by the engine's
    // row parser. `DDC26`: a name matching no parameter still becomes a chip,
    // so documentation drift loses the binding but never the text.
    check("param rows",
        "/**\nSummary.\nParams:\n    stray text with no equals\n"
        ~ "    gone = removed long ago\n*/\nint f(int x) => x;\n", 8,
        "Summary.", [["param", "gone removed long ago"]]);
}

@("ddoc.render.commentFormsAndAttachment")
@system unittest
{
    // `DDC2`-`DDC4`, `DDC6`, `DDC8`-`DDC10`, `DDC12`, `DDC13`: the lexer-level
    // shapes a doc comment can take. The engine handles all of these; nothing
    // pinned them, so a regression in the comment plumbing (the margin strip,
    // the `///` run, the postfix form) would have surfaced as missing docs
    // rather than as a failing test.
    static void check(string label, string src, uint line, string want, uint col = 5)
    {
        const t = tipIn(src, line, col);
        assert(t.doc == want, label ~ ": " ~ t.doc);
    }

    check("DDC2 /++ with extra +", "/++++\nSummary here.\n+/\nint a;\n", 5,
        "Summary here.");
    check("DDC3 consecutive ///", "/// First line.\n/// Second line.\nint b;\n", 4,
        "First line.\nSecond line.");
    check("DDC4 `*` margin stripped", "/**\n * One.\n * Two.\n */\nint c;\n", 6,
        "One.\nTwo.");
    // A blank line inside an embedded code block does not end the Summary.
    check("DDC6 blank in code", "/**\n---\nint x;\n\nint y;\n---\nAfter.\n*/\nint d;\n",
        10, "```d\nint x;\n\nint y;\n```\n\nAfter.");
    check("DDC8 two comments concatenate", "/** One. */\n/** Two. */\nint e;\n", 4,
        "One.\nTwo.");
    check("DDC9 postfix documents the decl", "int f; /// To the right.\n", 2,
        "To the right.");
    check("DDC10 prefix and postfix both apply", "/** Before. */ int g; /// After.\n",
        2, "Before.\n\nAfter.", 20);
    check("DDC12 enum member", "enum E\n{\n    /// The first one.\n    a,\n}\n", 5,
        "The first one.");
    // Legal, and must yield empty docs rather than a crash or a stray heading.
    check("DDC13 empty comment", "///\nint h;\n", 3, "");
}

@("ddoc.render.fenceContentIsVerbatim")
@system unittest
{
    // `DDC31`: inside a fence every line is the code's own. Blank runs and
    // indentation used to be normalized globally — the blank-line fold and the
    // trailing-space strip ran with no idea where the fences were, so a code
    // block came out reflowed.
    const tip = tipIn("/**\n"
        ~ "Body.\n"
        ~ "\n"
        ~ "---\n"
        ~ "void f()\n"
        ~ "{\n"
        ~ "\n"
        ~ "\n"
        ~ "    deep();\n"
        ~ "}\n"
        ~ "---\n"
        ~ "*/\n"
        ~ "int j;\n", 14, 5);
    // The trailing newline after the closing fence is deliberate: without it a
    // markdown parser reads the fence marker as part of the code.
    assert(tip.doc == "Body.\n\n```d\nvoid f()\n{\n\n\n    deep();\n}\n```\n",
        tip.doc);
}

@("ddoc.render.strayParensDoNotCorruptTheRest")
@system unittest
{
    // `DDC37`: `renderDdocText` bypasses `Section.write` for non-`Params`
    // sections, which also skips `escapeStrayParenthesis`. Checked against
    // `dmd -D` on the same input: prose parens behave identically, so the
    // divergence is narrower than it looks — it is one malformed macro.
    const open_ = tipIn("/**\nCounts (approximately and then $(B bold) after.\n*/\n"
        ~ "int a;\n", 5, 5);
    assert(open_.doc == "Counts (approximately and then **bold** after.", open_.doc);

    const close_ = tipIn("/**\nCounts approximately) and then $(B bold) after.\n*/\n"
        ~ "int b;\n", 5, 5);
    assert(close_.doc == "Counts approximately) and then **bold** after.", close_.doc);

    // The one divergence, pinned so a change is noticed: an unmatched `$(`
    // leaves its `$` here, where dmd's escape pass renders a bare `(`.
    const macro_ = tipIn("/**\nText $(B bold (unclosed) tail.\n*/\nint c;\n", 5, 5);
    assert(macro_.doc == "Text $(B bold (unclosed) tail.", macro_.doc);
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
