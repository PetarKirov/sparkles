// The DSV data-browser state machine (`docs/specs/hue/dsv-preview.md`
// `DSB1`/`DSB2`/`DSS1`/`DSF1`–`DSF3`/`DSF5`): one regular value every surface
// edits — sort keys, the parsed filter (typed column constraints + fuzzy
// remainder parts), and column visibility — resolved into the `DsvProjection`
// the adapter and `DsvCopy` consume. Presentation-free and unit-tested (the
// `TBL5` doctrine): no raylib, no terminal, no clock.
//
// The filter bar follows the picker's query doctrine (`PKQ` lexing rules:
// whitespace tokens, double quotes, backslash escapes, `!` negation) with
// column constraints `name:value` — operators `=`, `>`, `>=`, `<`, `<=`, an
// empty value for is-empty, `#N` 1-based column addressing — ANDed by the
// engine; the fuzzy remainder is matched per part per cell through
// `sparkles:fuzzy` (`DSF3`: a row admits a part when ANY cell admits it, and
// admits overall when EVERY part does).
module dsv_browser;

import dsv_view : DsvInfo, DsvProjection;
import sparkles.dsv : ColumnType, Constraint, ConstraintOp, decodeCell,
    Dialect, DsvDoc, parseDsv, ProjectionSpec, SortKey;

import sparkles.base.smallbuffer : SmallBuffer;

/// The browser's whole state (`DSB1`). Constraint/part values borrow from
/// `queryText`, which this value owns.
struct DsvBrowser
{
    SortKey[] sortKeys;
    Constraint[] constraints;
    string queryText;      /// the filter bar's applied text
    string[] fuzzyParts;   /// the query's fuzzy remainder (`DSF3`)
    uint[] hiddenCols;     /// hidden data columns, ascending
    string filterError;    /// `DSF5`: non-empty = the last apply failed

    bool pristine() const @safe pure nothrow @nogc
        => sortKeys.length == 0 && constraints.length == 0
            && fuzzyParts.length == 0 && hiddenCols.length == 0;

    /// `DSB2`: back to source order, no filter, all columns.
    void reset() @safe pure nothrow
    {
        sortKeys = null;
        constraints = null;
        queryText = null;
        fuzzyParts = null;
        hiddenCols = null;
        filterError = null;
    }

    /// `DSS1`: a plain activation on data column `col` cycles it as the
    /// PRIMARY key (asc → desc → removed), demoting existing keys behind it;
    /// `append` (Shift) instead appends it as the next key, or cycles it in
    /// place when already a key.
    void cycleSort(uint col, bool append) @safe pure nothrow
    {
        ptrdiff_t at = -1;
        foreach (i, k; sortKeys)
            if (k.column == col)
            {
                at = i;
                break;
            }

        if (append)
        {
            if (at < 0)
                sortKeys ~= SortKey(col);
            else if (!sortKeys[at].descending)
                sortKeys[at].descending = true;
            else
                sortKeys = sortKeys[0 .. at] ~ sortKeys[at + 1 .. $];
            return;
        }

        if (at == 0)
        {
            if (!sortKeys[0].descending)
                sortKeys[0].descending = true;
            else
                sortKeys = sortKeys[1 .. $];
            return;
        }
        if (at > 0)
            sortKeys = sortKeys[0 .. at] ~ sortKeys[at + 1 .. $];
        sortKeys = SortKey(col) ~ sortKeys;
    }

    /// Toggles data column `col`'s visibility (`DSB3`'s state half). At
    /// least one column stays visible: hiding the last one is refused.
    bool toggleColumn(uint col, uint totalCols) @safe pure nothrow
    {
        foreach (i, h; hiddenCols)
            if (h == col)
            {
                hiddenCols = hiddenCols[0 .. i] ~ hiddenCols[i + 1 .. $];
                return true;
            }
        if (hiddenCols.length + 1 >= totalCols)
            return false;
        // keep ascending
        size_t at = hiddenCols.length;
        foreach (i, h; hiddenCols)
            if (h > col)
            {
                at = i;
                break;
            }
        hiddenCols = hiddenCols[0 .. at] ~ [col] ~ hiddenCols[at .. $];
        return true;
    }

    /// `DSF1`/`DSF5`: parses and applies `query`. On a parse error the
    /// previous filter stays and `filterError` carries the message.
    bool setFilter(string query, const(char[])[] headerNames) @safe pure
    {
        Constraint[] cs;
        string[] parts;
        const err = parseFilterQuery(query, headerNames, cs, parts);
        if (err.length)
        {
            filterError = err;
            return false;
        }
        filterError = null;
        queryText = query;
        constraints = cs;
        fuzzyParts = parts;
        return true;
    }

    /// The engine/adapter projection (`DSB1`); the host attaches the fuzzy
    /// `rowMask` (`DSF3`) separately since it needs the parsed document.
    DsvProjection projection(uint totalCols) const @safe pure nothrow
    {
        DsvProjection p;
        p.spec = ProjectionSpec(sortKeys.dup, constraints.dup);
        if (hiddenCols.length)
        {
            auto cols = new uint[](0);
            outer: foreach (c; 0 .. totalCols)
            {
                foreach (h; hiddenCols)
                    if (h == c)
                        continue outer;
                cols ~= c;
            }
            p.columns = cols;
        }
        return p;
    }

    /// The `DSK5` projection chrome segment, e.g.
    /// `sort 2↑ 1↓ · filter · 1 col hidden` ("" when pristine).
    string chromeNote() const @safe pure
    {
        import std.conv : text;

        if (pristine)
            return "";
        string s;
        void seg(string t) { s ~= s.length ? " · " ~ t : t; }
        if (sortKeys.length)
        {
            string keys;
            foreach (k; sortKeys)
                keys ~= text(keys.length ? " " : "", k.column + 1,
                    k.descending ? "↓" : "↑");
            seg(text("sort ", keys));
        }
        if (constraints.length || fuzzyParts.length)
            seg("filter");
        if (hiddenCols.length)
            seg(text(hiddenCols.length, hiddenCols.length == 1
                ? " col hidden" : " cols hidden"));
        return s;
    }
}

// ── The filter query parser (`DSF1`/`DSF2`) ─────────────────────────────────

/// Splits `query` into decoded whitespace-separated tokens; double quotes
/// group, backslash escapes the next byte (the `PKQ` lexing rules). A
/// trailing backslash or unclosed quote is an error.
private string tokenize(string query, ref string[] tokens) @safe pure
{
    string cur;
    bool any, inQuotes;
    size_t i;
    while (i < query.length)
    {
        const c = query[i];
        if (c == '\\')
        {
            if (i + 1 >= query.length)
                return "trailing backslash";
            cur ~= query[i + 1];
            any = true;
            i += 2;
            continue;
        }
        if (c == '"')
        {
            inQuotes = !inQuotes;
            any = true;
            i++;
            continue;
        }
        if (!inQuotes && (c == ' ' || c == '\t'))
        {
            if (any)
                tokens ~= cur;
            cur = null;
            any = false;
            i++;
            continue;
        }
        cur ~= c;
        any = true;
        i++;
    }
    if (inQuotes)
        return "unclosed quote";
    if (any)
        tokens ~= cur;
    return null;
}

/// Parses one applied filter query into constraints + fuzzy parts; returns
/// "" on success, else the error message (`DSF5`).
string parseFilterQuery(string query, const(char[])[] headerNames,
    out Constraint[] constraints, out string[] fuzzyParts) @safe pure
{
    import std.conv : text;

    string[] tokens;
    const lexErr = tokenize(query, tokens);
    if (lexErr.length)
        return lexErr;

    foreach (tok; tokens)
    {
        bool negate = false;
        string t = tok;
        if (t.length >= 2 && t[0] == '!' && t[1] == '!')
            t = t[1 .. $]; // `!!x` is fuzzy text starting with `!` (PKQ3)
        else if (t.length >= 1 && t[0] == '!')
        {
            negate = true;
            t = t[1 .. $];
        }

        ptrdiff_t colon = -1;
        foreach (i, char c; t)
            if (c == ':')
            {
                colon = i;
                break;
            }
        if (colon < 0)
        {
            if (negate)
                return text("'!", t, "': only a column constraint can be negated");
            if (t.length >= 2)
                fuzzyParts ~= t;
            continue; // a 1-char part is dropped, the PKQ rule
        }

        const name = t[0 .. colon];
        string value = t[colon + 1 .. $];
        uint col;
        if (name.length >= 2 && name[0] == '#')
        {
            uint n = 0;
            foreach (char c; name[1 .. $])
            {
                if (c < '0' || c > '9')
                    return text("'", name, "': not a column number");
                n = n * 10 + (c - '0');
            }
            if (n == 0 || n > headerNames.length)
                return text("'", name, "': out of range (", headerNames.length,
                    " columns)");
            col = n - 1;
        }
        else
        {
            ptrdiff_t found = -1;
            foreach (i, h; headerNames)
                if (asciiEqNoCase(name, h))
                {
                    found = i;
                    break;
                }
            if (found < 0)
                return text("unknown column '", name, "'");
            col = cast(uint) found;
        }

        ConstraintOp op;
        if (value.length == 0)
            op = ConstraintOp.empty;
        else if (value[0] == '=')
        {
            op = ConstraintOp.eq;
            value = value[1 .. $];
        }
        else if (value.length >= 2 && value[0 .. 2] == ">=")
        {
            op = ConstraintOp.ge;
            value = value[2 .. $];
        }
        else if (value.length >= 2 && value[0 .. 2] == "<=")
        {
            op = ConstraintOp.le;
            value = value[2 .. $];
        }
        else if (value[0] == '>')
        {
            op = ConstraintOp.gt;
            value = value[1 .. $];
        }
        else if (value[0] == '<')
        {
            op = ConstraintOp.lt;
            value = value[1 .. $];
        }
        else
            op = ConstraintOp.contains;

        constraints ~= Constraint(col, op, negate, value);
    }
    return null;
}

private bool asciiEqNoCase(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if ((a[i] | 0x20) != (b[i] | 0x20))
            return false;
    return true;
}

// ── The fuzzy remainder (`DSF3`) ────────────────────────────────────────────

/// The per-record admission mask for the query's fuzzy parts: a data record
/// admits when EVERY part is admitted by SOME cell (typo-tolerant, through
/// `sparkles:fuzzy`'s canonical bounded-deletion witness). Returns null when
/// there are no parts (no masking). A cell the matcher cannot take (over its
/// byte cap) falls back to a plain case-insensitive substring test.
bool[] fuzzyRowMask(string dsvText, in DsvInfo info, const(string)[] parts) @safe
{
    import sparkles.fuzzy : CandidateView, DefaultFuzzyCaps, MatcherWorkspace,
        MatchKind, match, parseQuery;

    if (!parts.length || !info.present)
        return null;

    auto res = parseDsv(dsvText, info.dialect);
    if (res.hasError)
        return null;
    auto doc = res.value;
    doc.hasHeader = info.hasHeader;

    // One parsed query per part (a part is one fuzzy term by construction).
    alias Query = typeof(parseQuery("").value);
    auto queries = new Query[](0);
    foreach (p; parts)
    {
        auto q = parseQuery(p);
        if (!q.hasError)
            queries ~= q.value;
    }
    if (!queries.length)
        return null;

    auto ws = new MatcherWorkspace!DefaultFuzzyCaps;
    SmallBuffer!(char, 256) cellBuf;
    const first = doc.hasHeader ? 1 : 0;
    const total = doc.records.length - (doc.records.length ? first : 0);
    auto mask = new bool[](total);

    foreach (r; 0 .. total)
    {
        const rec = doc.records[first + r];
        bool all = true;
        foreach (ref q; queries)
        {
            bool anyCell = false;
            foreach (ci; 0 .. rec.cellCount)
            {
                const cell = decodeCell(doc, doc.cells[rec.cellsStart + ci],
                    cellBuf);
                if (cell.length == 0)
                    continue;
                auto m = match(q, CandidateView(path: cell), *ws);
                if (m.hasError)
                {
                    // Over-cap or exotic cell: degrade to substring.
                    anyCell = containsNoCase(cell, parts[0]);
                }
                else
                    anyCell = m.value.kind != MatchKind.rejected;
                if (anyCell)
                    break;
            }
            if (!anyCell)
            {
                all = false;
                break;
            }
        }
        mask[r] = all;
    }
    return mask;
}

private bool containsNoCase(scope const(char)[] hay, scope const(char)[] needle)
    @safe pure nothrow @nogc
{
    if (needle.length == 0 || needle.length > hay.length)
        return false;
    foreach (s; 0 .. hay.length - needle.length + 1)
    {
        bool ok = true;
        foreach (i; 0 .. needle.length)
            if ((hay[s + i] | 0x20) != (needle[i] | 0x20))
            {
                ok = false;
                break;
            }
        if (ok)
            return true;
    }
    return false;
}

// ── tests ───────────────────────────────────────────────────────────────────

@("dsv_browser.sort.cycleAndDemote")
@safe unittest
{
    DsvBrowser b;
    b.cycleSort(1, false);
    assert(b.sortKeys == [SortKey(1)]);
    b.cycleSort(1, false);
    assert(b.sortKeys == [SortKey(1, descending: true)]);
    b.cycleSort(1, false);
    assert(b.sortKeys.length == 0); // asc → desc → removed

    // A different column becomes THE primary, demoting the rest.
    b.cycleSort(1, false);
    b.cycleSort(2, false);
    assert(b.sortKeys == [SortKey(2), SortKey(1)]);
    // Clicking a current secondary promotes it to primary ascending.
    b.cycleSort(1, false);
    assert(b.sortKeys == [SortKey(1), SortKey(2)]);
}

@("dsv_browser.sort.appendMode")
@safe unittest
{
    DsvBrowser b;
    b.cycleSort(0, false);
    b.cycleSort(2, true);
    assert(b.sortKeys == [SortKey(0), SortKey(2)]);
    b.cycleSort(2, true); // in-place desc
    assert(b.sortKeys == [SortKey(0), SortKey(2, descending: true)]);
    b.cycleSort(2, true); // in-place removal
    assert(b.sortKeys == [SortKey(0)]);
}

@("dsv_browser.columns.toggleKeepsOne")
@safe unittest
{
    DsvBrowser b;
    assert(b.toggleColumn(2, 3));
    assert(b.toggleColumn(0, 3));
    assert(b.hiddenCols == [0u, 2]); // kept ascending
    assert(!b.toggleColumn(1, 3)); // the last visible column stays
    assert(b.toggleColumn(0, 3)); // un-hide
    assert(b.hiddenCols == [2u]);
}

@("dsv_browser.filter.parseAndApply")
@safe unittest
{
    const(char[])[] headers = ["name", "unit price", "ok"];
    DsvBrowser b;
    assert(b.setFilter(`name:al "unit price":>=10 !ok:=false qu`, headers));
    assert(b.constraints.length == 3);
    assert(b.constraints[0] == Constraint(0, ConstraintOp.contains, false, "al"));
    assert(b.constraints[1] == Constraint(1, ConstraintOp.ge, false, "10"));
    assert(b.constraints[2] == Constraint(2, ConstraintOp.eq, true, "false"));
    assert(b.fuzzyParts == ["qu"]);
    assert(b.filterError.length == 0);
}

@("dsv_browser.filter.indexAndOps")
@safe unittest
{
    const(char[])[] headers = ["a", "b"];
    DsvBrowser b;
    assert(b.setFilter("#2:<5 a: x", headers));
    assert(b.constraints[0] == Constraint(1, ConstraintOp.lt, false, "5"));
    assert(b.constraints[1] == Constraint(0, ConstraintOp.empty, false, ""));
    assert(b.fuzzyParts.length == 0); // "x" dropped (1 char)
}

@("dsv_browser.filter.errorsKeepPrevious")
@safe unittest
{
    const(char[])[] headers = ["a"];
    DsvBrowser b;
    assert(b.setFilter("a:1", headers));
    const prev = b.constraints;
    assert(!b.setFilter("nope:1", headers));
    assert(b.filterError == "unknown column 'nope'");
    assert(b.constraints is prev); // DSF5: the previous filter stays
    assert(!b.setFilter("#9:1", headers));
    assert(!b.setFilter(`"unclosed`, headers));
    assert(!b.setFilter("!loose", headers));
}

@("dsv_browser.projectionAndChrome")
@safe unittest
{
    DsvBrowser b;
    assert(b.pristine && b.chromeNote == "");
    b.cycleSort(1, false);
    b.cycleSort(1, false);
    b.cycleSort(0, true);
    assert(b.toggleColumn(2, 4));
    const p = b.projection(4);
    assert(p.spec.sortKeys == [SortKey(1, descending: true), SortKey(0)]);
    assert(p.columns == [0u, 1, 3]);
    assert(!p.pristine);
    assert(b.chromeNote == "sort 2↓ 1↑ · 1 col hidden");
    b.reset();
    assert(b.pristine);
}

@("dsv_browser.fuzzyRowMask.typoTolerantAnyCell")
@safe unittest
{
    const src = "name,tag\nalice,blue\nbob,green\ncarol,cyan\n";
    DsvInfo info = {
        present: true, dialect: Dialect(','), hasHeader: true,
    };
    // "gren" admits "green" (one deletion); parts AND across cells.
    const m = fuzzyRowMask(src, info, ["gren"]);
    assert(m == [false, true, false]);
    const both = fuzzyRowMask(src, info, ["carol", "cyan"]);
    assert(both == [false, false, true]);
    assert(fuzzyRowMask(src, info, null) is null);
}
