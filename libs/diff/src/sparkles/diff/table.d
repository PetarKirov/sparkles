/**
Pipe-table structure for the noise layers (`DVN4`).

The motivating scenario of the whole diff feature: a formatter re-aligns every
row of a markdown table and the one real edit drowns in the padding. `DVN1`
solves it when the reviewer opts into a whitespace policy; this module solves
the parts that whitespace normalization provably cannot:

$(UL
$(LI A **separator row** — `| ---- | ---- |` becoming `| ------- | ---- |` —
    differs in dash COUNT, which is content to a text differ and column width
    to a markdown reader. No whitespace policy can bridge that.)
$(LI **Which cell changed.** Word refinement emphasizes changed tokens, but a
    re-padded row has changed tokens everywhere. Splitting on cell boundaries
    is what lets exactly one cell light up.)
)

$(B Why this is here and not behind tree-sitter.) The engine is deliberately
grammar-free ([diff-view.md](../../../../docs/specs/hue/diff-view.md)
decision 5), and a pipe-table row does not need a parser: it is text between
unescaped `|` characters. That is a lexical fact, not a syntactic one. The
grammar-driven path (`MdDoc` block structure, for the rendered-preview diff
`DVN6`) belongs where `sparkles:syntax` already is — this is the cheap layer
that covers the case people actually hit.

$(B What this deliberately does not do:) decide that something IS a table.
A line starting and ending with `|` might be a table row, a code sample, or
prose about pipes. Every predicate here is a heuristic used only to make a
change LESS alarming — never to hide one — so a false positive costs a
reviewer a dimmed row they can expand, not a missed edit.
*/
module sparkles.diff.table;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.diff.model : Span;
import sparkles.diff.normalize : isSpace, withoutTrailingSpace;

/// The maximum cells a row may have before the cell passes give up and leave
/// it to word refinement — a guard in the `DVM6` family, so a pathological
/// line of thousands of pipes cannot make refinement quadratic.
enum size_t maxCells = 128;

/**
`true` when `line` looks like a pipe-table row: it contains at least one
unescaped `|` outside the leading whitespace, and (after trimming) begins with
one.

Requiring the leading pipe is the conservative half of the heuristic. GFM
allows a table row without outer pipes, but so does any line of prose
containing a pipe, and mistaking prose for a table would let the cell passes
call a real edit "padding".
*/
bool isTableRow(scope const(char)[] line) @safe pure nothrow @nogc
{
    const t = trimmed(line);
    if (t.length < 2 || t[0] != '|')
        return false;
    // A second unescaped pipe: one alone is a leading pipe with no cell.
    size_t i = 1;
    while (i < t.length)
    {
        if (t[i] == '\\')
        {
            i += 2;
            continue;
        }
        if (t[i] == '|')
            return true;
        ++i;
    }
    return false;
}

/**
Appends the cell spans of `line` (byte ranges into `line`) to `cells`,
returning the number appended, or `0` when `line` is not a table row or has
more than $(LREF maxCells) cells.

Spans cover the cell's **full** text including its padding, because that is
what a renderer must emphasize; comparison trims (see $(LREF cellsEqual)).
The outer pipes' empty edge cells are dropped: `| a | b |` has two cells, not
four.
*/
size_t cellSpans(scope const(char)[] line, ref SmallBuffer!Span cells)
    @safe pure nothrow @nogc
{
    if (!isTableRow(line))
        return 0;

    const startOffset = leadingSpace(line);
    const t = trimmed(line);
    const before = cells.length;

    size_t cellStart = 1; // just past the leading pipe
    size_t i = 1;
    while (i <= t.length)
    {
        if (i == t.length)
        {
            // Trailing text after the last pipe — only a cell if non-empty
            // (a well-formed row ends with `|`, leaving nothing here).
            if (cellStart < t.length)
                cells ~= Span(startOffset + cellStart, t.length - cellStart);
            break;
        }
        if (t[i] == '\\')
        {
            i += 2;
            continue;
        }
        if (t[i] == '|')
        {
            cells ~= Span(startOffset + cellStart, i - cellStart);
            cellStart = i + 1;
            if (cells.length - before > maxCells)
            {
                cells.length = before;
                return 0;
            }
        }
        ++i;
    }
    return cells.length - before;
}

/// `true` when the two cell texts say the same thing — trimmed, since cell
/// padding is exactly what a table formatter moves around.
bool cellsEqual(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
    => trimmed(a) == trimmed(b);

/**
`true` when `line` is a table's **separator** row: every cell is dashes with
optional leading/trailing colons (`---`, `:---`, `---:`, `:---:`).

This is the row a formatter widens along with the columns, and the one a text
differ has no way to forgive — its dashes are content.
*/
bool isSeparatorRow(scope const(char)[] line) @safe pure nothrow @nogc
{
    SmallBuffer!Span cells;
    const n = cellSpans(line, cells);
    if (n == 0)
        return false;
    foreach (i; 0 .. n)
    {
        const c = trimmed(line[cells[i].start .. cells[i].end]);
        if (!isSeparatorCell(c))
            return false;
    }
    return true;
}

private bool isSeparatorCell(scope const(char)[] c) @safe pure nothrow @nogc
{
    size_t i = 0;
    if (i < c.length && c[i] == ':')
        ++i;
    size_t dashes;
    while (i < c.length && c[i] == '-')
    {
        ++i;
        ++dashes;
    }
    if (i < c.length && c[i] == ':')
        ++i;
    return dashes != 0 && i == c.length;
}

/**
`true` when `a` and `b` are table rows whose cells match one-for-one, ignoring
padding — i.e. the pair differs only in alignment.

Separator rows are compared by **shape**, not by dash count: two separator rows
with the same cell count and the same colon alignment markers are the same row
re-drawn. That is the case `DVN1` structurally cannot reach.
*/
bool rowsEquivalent(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    SmallBuffer!Span ca, cb;
    const na = cellSpans(a, ca);
    const nb = cellSpans(b, cb);
    if (na == 0 || na != nb)
        return false;

    const sepA = isSeparatorRow(a);
    if (sepA != isSeparatorRow(b))
        return false;

    foreach (i; 0 .. na)
    {
        const x = trimmed(a[ca[i].start .. ca[i].end]);
        const y = trimmed(b[cb[i].start .. cb[i].end]);
        if (sepA)
        {
            // Same alignment, any width.
            if (alignmentOf(x) != alignmentOf(y))
                return false;
        }
        else if (x != y)
            return false;
    }
    return true;
}

/// A separator cell's alignment: 0 none, 1 left (`:---`), 2 right (`---:`),
/// 3 centre (`:---:`) — the only part of a separator that carries meaning.
private ubyte alignmentOf(scope const(char)[] c) @safe pure nothrow @nogc
{
    if (c.length == 0)
        return 0;
    const left = c[0] == ':';
    const right = c[$ - 1] == ':' && c.length > 1;
    return cast(ubyte)((left ? 1 : 0) | (right ? 2 : 0));
}

private size_t leadingSpace(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t i;
    while (i < s.length && isSpace(s[i]))
        ++i;
    return i;
}

private const(char)[] trimmed(return scope const(char)[] s) @safe pure nothrow @nogc
    => withoutTrailingSpace(s[leadingSpace(s) .. $]);

// ── Tests ───────────────────────────────────────────────────────────────────

@("table.isTableRow.heuristicIsConservative")
@safe pure nothrow @nogc
unittest
{
    assert(isTableRow("| a | b |"));
    assert(isTableRow("|a|"));
    assert(isTableRow("  | a | b |  "), "indented rows still count");
    // Prose about pipes is not a table row: no leading pipe.
    assert(!isTableRow("use a | b to pipe"));
    assert(!isTableRow("|no closing pipe"), "one pipe is a leading pipe only");
    assert(!isTableRow("") && !isTableRow("|"));
    // An escaped pipe is not a cell boundary.
    assert(!isTableRow(`|a \| b`));
}

@("table.cellSpans.dropsTheOuterEmptyCells")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!Span cells;
    enum row = "| ann | dev |";
    assert(cellSpans(row, cells) == 2, "two cells, not four");
    assert(row[cells[0].start .. cells[0].end] == " ann ");
    assert(row[cells[1].start .. cells[1].end] == " dev ");

    // Spans cover the padding, because that is what a renderer highlights.
    cells.clear();
    enum padded = "| ann     | dev |";
    assert(cellSpans(padded, cells) == 2);
    assert(padded[cells[0].start .. cells[0].end] == " ann     ");

    // Indented rows resolve against the ORIGINAL line, not the trimmed view.
    cells.clear();
    enum indented = "   | x | y |";
    assert(cellSpans(indented, cells) == 2);
    assert(indented[cells[0].start .. cells[0].end] == " x ");
}

@("table.isSeparatorRow.dashesAndAlignment")
@safe pure nothrow @nogc
unittest
{
    assert(isSeparatorRow("| --- | --- |"));
    assert(isSeparatorRow("| :--- | ---: | :---: |"));
    assert(isSeparatorRow("|-|-|"));
    assert(!isSeparatorRow("| a | --- |"), "one content cell is enough");
    assert(!isSeparatorRow("| | --- |"), "an empty cell has no dashes");
}

@("table.rowsEquivalent.paddingAndSeparatorWidth")
@safe pure nothrow @nogc
unittest
{
    // The everyday case: same content, re-aligned.
    assert(rowsEquivalent("| ann | dev |", "| ann     | dev |"));
    // The case DVN1 cannot reach: a widened separator is the same separator.
    assert(rowsEquivalent("| ---- | ---- |", "| ------- | ---- |"));
    // …but alignment is meaning, so changing it is a real change.
    assert(!rowsEquivalent("| ---- | ---- |", "| :----- | ---- |"));

    // A real edit is never equivalent, however it is padded.
    assert(!rowsEquivalent("| ann | dev |", "| ann | ops |"));
    // Nor is a row that gained or lost a column.
    assert(!rowsEquivalent("| a | b |", "| a | b | c |"));
    // A separator and a content row are never the same row.
    assert(!rowsEquivalent("| --- | --- |", "| a | b |"));
    // Non-table lines are never equivalent — the predicate must not claim
    // authority over ordinary prose.
    assert(!rowsEquivalent("hello", "hello"));
}
