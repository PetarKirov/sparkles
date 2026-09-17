/++
Verify that the symbols a specification cites in its evidence column exist.

[Writing Specification Docs](../../docs/guidelines/spec-docs.md) makes the
requirement table the delivery gate and the $(B Traces to) column the falsifiable
link from a requirement to the code that satisfies it. A row marked `full` whose
evidence names nothing is therefore worse than an undocumented feature: it is a
gate reporting success it never checked, and the next reader to ask "is this
done?" is told yes by a table that looked.

This is not hypothetical drift. The audit that motivated this check found eleven
cited symbols resolving to nothing across `docs/specs/hue/gui.md` and
`docs/specs/ui/backends.md` — among them `CrtEffect.renderBloomPass`,
`bloomIntensity` and `flatten_strength`, all naming a design that was written
about and never built, under rows marked `full`.

$(B The check is deliberately conservative.) A false positive here is expensive:
the check is only useful if people leave it on, and a check that cries about
prose gets switched off. So a token is reported only when it $(I looks like a
symbol and resolves nowhere) — a spelling this module declines to classify is
left alone, and $(LREF isSymbolLike) is where that judgement lives.

Complements `--check-docs-sidebar` (are pages linked?) and `--check-vcs-urls`
(are citations pinned?): this one asks whether the citation is $(I true).
+/
module spec_evidence;

import std.algorithm : canFind, startsWith, endsWith;
import std.array : array, split;
import std.ascii : isAlphaNum, isDigit, isHexDigit;
import std.string : indexOf, strip;

/// One cited token, with where it was cited from.
struct Citation
{
    string token;  /// the spelling, exactly as written between backticks
    string id;     /// the requirement id the row states (`CRT3`), empty if unread
    string file;   /// the spec file it was cited in
    size_t line;   /// 1-based line number within `file`
}

/// Header cells whose column carries evidence.
private enum evidenceHeaders = ["traces to", "evidence"];

/++
Whether a backticked token is worth resolving at all.

Everything this returns `false` for is something a spec legitimately writes in
an evidence column that is not a symbol: a status word, a CLI flag, a commit
sha, a prose fragment, a requirement id, a bare number. The bias is toward
`false` — see the module note on false positives.
+/
bool isSymbolLike(scope const(char)[] token) @safe pure nothrow
{
    if (token.length == 0 || token.length > 200)
        return false;

    // Prose, not a symbol: anything with a space, or bracketed/parenthesised.
    foreach (c; token)
        if (c == ' ' || c == '(' || c == ')' || c == '[' || c == ']' ||
            c == ',' || c == '<' || c == '>' || c == '"' || c == '\'')
            return false;

    // CLI flags and env vars are real, but they are not D symbols and are
    // checked (or not) by other means.
    if (token[0] == '-' || token[0] == '$')
        return false;

    // A bare commit sha, or any run of hex long enough to be one.
    if (token.length >= 7 && token.length <= 40)
    {
        bool allHex = true;
        foreach (c; token)
            if (!c.isHexDigit) { allHex = false; break; }
        if (allHex)
            return false;
    }

    // Numbers, versions, percentages.
    if (token[0].isDigit)
        return false;

    // Status words and table furniture.
    static immutable string[] stop = [
        "full", "partial", "none", "planned", "n/a", "na", "yes", "no",
        "tbd", "wip", "todo", "id", "requirement", "status",
    ];
    foreach (w; stop)
        if (token.length == w.length)
        {
            bool same = true;
            foreach (i, c; token)
            {
                const lc = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
                if (lc != w[i]) { same = false; break; }
            }
            if (same)
                return false;
        }

    // A bare upper-case run is a requirement-id prefix (`CAT`, `THM`, `LNG`),
    // which specs use to name a whole family of rows.
    {
        bool allUpper = true;
        foreach (c; token)
            if (!(c >= 'A' && c <= 'Z')) { allUpper = false; break; }
        if (allUpper && token.length <= 6)
            return false;
    }

    // A requirement id (`CRT3`, `TGT12`, `PTR1`): upper-case run then digits.
    // These are cross-references within the table, not code.
    {
        size_t i = 0;
        while (i < token.length && token[i] >= 'A' && token[i] <= 'Z')
            ++i;
        if (i >= 2 && i < token.length)
        {
            size_t j = i;
            while (j < token.length && token[j].isDigit)
                ++j;
            if (j == token.length)
                return false;
        }
    }

    // Must start like an identifier and contain only identifier-ish bytes.
    if (!(token[0].isAlphaNum || token[0] == '_'))
        return false;
    foreach (c; token)
        if (!(c.isAlphaNum || c == '_' || c == '.' || c == '/' || c == ':'))
            return false;

    return true;
}

@("spec_evidence.isSymbolLike.classifiesWhatASpecActuallyWrites")
@safe pure nothrow
unittest
{
    // Symbols — the things the check exists to resolve.
    assert(isSymbolLike("CrtEffect.systemPointer"));
    assert(isSymbolLike("crt.d"));
    assert(isSymbolLike("applyScissor"));
    assert(isSymbolLike("ui_raylib.crt_projection.magnifierLensIsCentredOnTheCursor"));
    assert(isSymbolLike("libs/ui/src/sparkles/ui/state.d"));

    // Not symbols — every one of these appears in a real evidence column.
    assert(!isSymbolLike("full"));
    assert(!isSymbolLike("partial"));
    assert(!isSymbolLike("--gui"));
    assert(!isSymbolLike("$SPARKLES_TS_GRAMMAR_PATH"));
    assert(!isSymbolLike("a0b0f93a"));              // short sha
    assert(!isSymbolLike("e6063309"));
    assert(!isSymbolLike("CRT3"));                  // a sibling requirement id
    assert(!isSymbolLike("TGT12"));
    assert(!isSymbolLike("PTR1"));
    assert(!isSymbolLike("CAT"));                   // an id PREFIX, not a symbol
    assert(!isSymbolLike("THM"));
    assert(!isSymbolLike("6.0.1"));
    assert(!isSymbolLike("one view, three targets"));
    assert(!isSymbolLike("Slot(thumb)"));
    assert(!isSymbolLike(""));

    // `DBG1`-style ids stay excluded, but a symbol that merely ends in a digit
    // is still a symbol.
    assert(isSymbolLike("vec2"));
    assert(isSymbolLike("sdl3"));
}

/++
Splits one evidence cell into the tokens worth resolving.

Backticked spans only: anything outside backticks is prose by construction. A
span may hold several tokens (``` `crt.d` `curve`/`curveStep` ```), so spans are
split further on `/` and whitespace.
+/
string[] citedTokens(scope const(char)[] cell) @safe pure
{
    string[] found;
    size_t i = 0;
    while (i < cell.length)
    {
        const open = cell[i .. $].indexOf('`');
        if (open < 0)
            break;
        const from = i + open + 1;
        if (from >= cell.length)
            break;
        const close = cell[from .. $].indexOf('`');
        if (close < 0)
            break;
        const span = cell[from .. from + close].idup;
        foreach (piece; span.split('/'))
            foreach (tok; piece.split(' '))
            {
                const t = tok.strip;
                if (isSymbolLike(t))
                    found ~= t.idup;
            }
        i = from + close + 1;
    }
    return found;
}

@("spec_evidence.citedTokens.readsBackticksAndSplitsSpans")
@safe pure
unittest
{
    assert(citedTokens("`crt.d` `curve`") == ["crt.d", "curve"]);
    assert(citedTokens("plain prose, no ticks") == []);
    assert(citedTokens("`applyScissor`/`popScissor`") == ["applyScissor", "popScissor"]);
    // Status words and ids inside ticks are still dropped.
    assert(citedTokens("`full` — see `CRT3`") == []);
    // A path is one token, not three.
    assert(citedTokens("`libs/ui/src/x.d`") == ["libs", "ui", "src", "x.d"]);
}

/++
The identifier a token must resolve to.

A dotted spelling cites a member (`CrtEffect.systemPointer`) or a test name
(`ui_raylib.crt.somethingHolds`); in both cases the $(I last) segment is the one
that must appear in the tree, because the qualifying path may be a module, a
type, or the test-name convention, and the check does not care which.
+/
string resolvableName(string token) @safe pure nothrow
{
    // `dock.d:826` cites a file AND a line. The line number is not a symbol
    // and cannot be checked (it moves with every edit above it), so strip it
    // and resolve the file.
    const colon = token.length ? indexOfLast(token, ':') : -1;
    if (colon > 0 && colon + 1 < token.length)
    {
        bool digits = true;
        foreach (c; token[colon + 1 .. $])
            if (!c.isDigit) { digits = false; break; }
        if (digits)
            token = token[0 .. colon];
    }

    ptrdiff_t dot = -1;
    foreach (i, c; token)
        if (c == '.')
            dot = i;
    if (dot < 0)
        return token;
    // A file name keeps its extension: `crt.d` is a file, not member `d`.
    const ext = token[dot .. $];
    if (ext == ".d" || ext == ".md" || ext == ".sdl" || ext == ".json" || ext == ".nix")
        return token;
    return token[dot + 1 .. $];
}

@("spec_evidence.resolvableName.keepsFilesAndTakesTheLastMember")
@safe pure nothrow
unittest
{
    assert(resolvableName("crt.d") == "crt.d");
    assert(resolvableName("display_list.d") == "display_list.d");
    assert(resolvableName("CrtEffect.systemPointer") == "systemPointer");
    assert(resolvableName("ui_raylib.crt.magnifierIsCentred") == "magnifierIsCentred");
    assert(resolvableName("applyScissor") == "applyScissor");
    // A file-and-line citation resolves as the file; the line is uncheckable.
    assert(resolvableName("dock.d:826") == "dock.d");
    assert(resolvableName("style.d:233") == "style.d");
    // A colon that is not a line number is left alone.
    assert(resolvableName("sparkles:ui") == "sparkles:ui");
}

private ptrdiff_t indexOfLast(scope const(char)[] s, char c) @safe pure nothrow
{
    ptrdiff_t at = -1;
    foreach (i, ch; s)
        if (ch == c)
            at = i;
    return at;
}

private bool isWordByte(char c) @safe pure nothrow
    => c.isAlphaNum || c == '_';

/++
Whether `name` occurs in `haystack` as a whole word.

Whole-word so that citing `curve` is not satisfied by `curvature`, which is
exactly the near-miss a stale evidence column produces.
+/
bool occursAsWord(scope const(char)[] haystack, scope const(char)[] name)
    @safe pure nothrow
{
    if (name.length == 0 || name.length > haystack.length)
        return false;
    foreach (i; 0 .. haystack.length - name.length + 1)
    {
        if (haystack[i .. i + name.length] != name)
            continue;
        const beforeOk = i == 0 || !isWordByte(haystack[i - 1]);
        const after = i + name.length;
        const afterOk = after == haystack.length || !isWordByte(haystack[after]);
        if (beforeOk && afterOk)
            return true;
    }
    return false;
}

@("spec_evidence.occursAsWord.wholeWordsOnly")
@safe pure nothrow
unittest
{
    assert(occursAsWord("void applyScissor() {}", "applyScissor"));
    assert(occursAsWord("float curve(vec2 c)", "curve"));
    // The near-miss a stale column produces: `curve` must NOT be satisfied by
    // `curvature`, nor `popScissor` by `applyScissor`.
    assert(!occursAsWord("float curvature = 0.08;", "curve"));
    assert(!occursAsWord("private void applyScissor()", "popScissor"));
    assert(occursAsWord("a.curve = 1", "curve"));
    assert(!occursAsWord("", "x"));
}

/++
Reads one markdown file and returns every citation in an evidence column.

Only requirement tables are read: a row counts when its table's header names an
evidence column ($(LREF evidenceHeaders)) and the row has as many cells. That
keeps prose, code fences and non-requirement tables out, so the check speaks
only where the spec is making a traceability claim.
+/
Citation[] citationsIn(string file, scope const(char)[] text) @safe pure
{
    import std.string : splitLines, toLower;

    Citation[] found;
    ptrdiff_t evidenceCol = -1;
    size_t columns;
    bool inFence;

    foreach (n, rawLine; text.splitLines)
    {
        const line = rawLine.strip;

        if (line.startsWith("```"))
        {
            inFence = !inFence;
            continue;
        }
        if (inFence)
            continue;

        if (!line.startsWith("|"))
        {
            evidenceCol = -1; // a table ends at the first non-row
            continue;
        }

        auto cells = line.split('|');
        // A leading and trailing `|` produce empty outer cells; drop them.
        if (cells.length >= 2)
            cells = cells[1 .. $ - 1];
        if (cells.length == 0)
            continue;

        // A separator row (`| --- | --- |`) confirms the header above it.
        bool separator = true;
        foreach (c; cells)
        {
            const t = c.strip;
            if (t.length == 0) { separator = false; break; }
            foreach (ch; t)
                if (ch != '-' && ch != ':') { separator = false; break; }
            if (!separator) break;
        }
        if (separator)
            continue;

        if (evidenceCol < 0)
        {
            // Header row: look for the evidence column.
            foreach (i, c; cells)
            {
                const h = c.strip.toLower;
                foreach (want; evidenceHeaders)
                    if (h == want)
                    {
                        evidenceCol = i;
                        columns = cells.length;
                    }
            }
            continue;
        }

        if (cells.length != columns || evidenceCol >= cells.length)
            continue;

        const id = cells[0].strip.idup;
        foreach (tok; citedTokens(cells[evidenceCol]))
            found ~= Citation(tok, id, file, n + 1);
    }
    return found;
}

@("spec_evidence.citationsIn.readsOnlyRequirementTables")
@safe pure
unittest
{
    enum doc = "# Title\n"
        ~ "\n"
        ~ "Prose citing `neverResolved` outside a table.\n"
        ~ "\n"
        ~ "| ID   | Requirement | Status | Traces to |\n"
        ~ "| ---- | ----------- | ------ | --------- |\n"
        ~ "| AAA1 | does a thing | full  | `realSymbol` |\n"
        ~ "| AAA2 | does another | none  | — |\n"
        ~ "\n"
        ~ "| Other | Table |\n"
        ~ "| ----- | ----- |\n"
        ~ "| x     | `alsoIgnored` |\n";

    const cites = citationsIn("t.md", doc);
    assert(cites.length == 1, "only the evidence column of a requirement table");
    assert(cites[0].token == "realSymbol");
    assert(cites[0].id == "AAA1");
    assert(cites[0].line == 7);
}

@("spec_evidence.citationsIn.ignoresFencedBlocks")
@safe pure
unittest
{
    enum doc = "| ID | Requirement | Traces to |\n"
        ~ "| -- | ----------- | --------- |\n"
        ~ "| A1 | thing | `kept` |\n"
        ~ "\n"
        ~ "```d\n"
        ~ "| not | a | table `ignored` |\n"
        ~ "```\n";
    const cites = citationsIn("t.md", doc);
    assert(cites.length == 1 && cites[0].token == "kept");
}

/// One citation that resolved nowhere.
struct Unresolved
{
    Citation cite;
    string name; /// the identifier actually looked for
}

/++
Resolves every citation against `sources` (path → contents) and returns the ones
that name nothing.

A token ending in a file extension resolves when some source path ends with it;
anything else resolves when its $(LREF resolvableName) occurs as a whole word in
any source.
+/
Unresolved[] unresolvedCitations(in Citation[] cites, in string[string] sources,
    in string[] paths = null) @safe pure
{
    Unresolved[] bad;
    foreach (c; cites)
    {
        const name = resolvableName(c.token);
        bool ok;
        if (name.endsWith(".d") || name.endsWith(".md") || name.endsWith(".sdl")
            || name.endsWith(".json") || name.endsWith(".nix"))
        {
            foreach (path; paths)
                if (path.endsWith(name)) { ok = true; break; }
            if (!ok)
                foreach (path, _; sources)
                    if (path.endsWith(name)) { ok = true; break; }
        }
        else
        {
            foreach (_, body_; sources)
                if (occursAsWord(body_, name)) { ok = true; break; }
        }
        if (!ok)
            bad ~= Unresolved(c, name);
    }
    return bad;
}

@("spec_evidence.unresolvedCitations.findsTheStaleOnesOnly")
@safe pure
unittest
{
    string[string] sources = [
        "libs/x/src/crt.d": "void curve() {}\nstruct CrtEffect { bool systemPointer; }\n",
    ];
    const cites = [
        Citation("crt.d", "A1", "s.md", 1),
        Citation("curve", "A1", "s.md", 1),
        Citation("CrtEffect.systemPointer", "A2", "s.md", 2),
        Citation("CrtEffect.renderBloomPass", "A3", "s.md", 3), // the real bug
        Citation("missing.d", "A4", "s.md", 4),
    ];
    const bad = unresolvedCitations(cites, sources);
    assert(bad.length == 2);
    assert(bad[0].cite.token == "CrtEffect.renderBloomPass");
    assert(bad[0].name == "renderBloomPass");
    assert(bad[1].cite.token == "missing.d");
}
