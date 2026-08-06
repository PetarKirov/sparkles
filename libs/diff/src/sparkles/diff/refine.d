/// The word-level refinement pass (`DVM4`): for each similarity-paired row
/// pair, a token-level LCS marks the changed segments as emphasis spans in
/// the document's `emph` arena. Guarded (`DVM6` / the survey's unanimous
/// finding that refinement needs guards or it produces confetti): a token
/// cap, and a changed-ratio gate above which the pair renders as whole-row
/// emphasis. `@nogc` (`DVM8`): `SmallBuffer` token lists and a flat LCS
/// table.
module sparkles.diff.refine;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.diff.model : DiffOptions, Row, RowKind, Span;
import sparkles.diff.table : cellsEqual, cellSpans, isSeparatorRow;

/// One token: a byte span of the row classified for diffing.
struct Token
{
    size_t start;
    size_t length;

    size_t end() const @safe pure nothrow @nogc => start + length;
}

/// Tokenize a row: identifier runs (`[A-Za-z0-9_]+`), whitespace runs, and
/// single other bytes (a multi-byte UTF-8 sequence stays one token).
SmallBuffer!Token tokenize(scope const(char)[] text) @safe pure nothrow @nogc
{
    static bool isWordByte(char c) @safe pure nothrow @nogc
        => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
    static bool isSpaceByte(char c) @safe pure nothrow @nogc => c == ' ' || c == '\t';

    SmallBuffer!Token tokens;
    size_t i = 0;
    while (i < text.length)
    {
        immutable start = i;
        immutable c = text[i];
        if (isWordByte(c))
        {
            while (i < text.length && isWordByte(text[i]))
                i++;
        }
        else if (isSpaceByte(c))
        {
            while (i < text.length && isSpaceByte(text[i]))
                i++;
        }
        else if (c < 0x80)
            i++;
        else
        {
            // One UTF-8 sequence.
            i++;
            while (i < text.length && (text[i] & 0xC0) == 0x80)
                i++;
        }
        tokens ~= Token(start, i - start);
    }
    return tokens;
}

/// Refine one paired row pair: appends both rows' changed segments to the
/// `emph` arena and points the rows at their ranges (or whole-row spans past
/// the changed-ratio gate). `aText`/`bText` are the rows' resolved texts.
void refinePair(ref Row oldRow, scope const(char)[] aText,
    ref Row newRow, scope const(char)[] bText,
    ref SmallBuffer!Span emphArena, in DiffOptions opt) @safe pure nothrow @nogc
{
    // `DVN4`: when both sides are pipe-table rows with the same shape, the
    // meaningful unit is the CELL, not the word. Word refinement would light
    // up every re-padded cell's whitespace tokens; cell refinement lights up
    // exactly the cells whose content differs, which is the motivating
    // scenario's whole point.
    if (opt.refineTableCells
        && refineTableRow(oldRow, aText, newRow, bText, emphArena))
        return;

    auto ta = tokenize(aText);
    auto tb = tokenize(bText);
    if (ta.length > opt.maxRefineTokens || tb.length > opt.maxRefineTokens)
        return; // guard: no refinement, rows render plainly

    // LCS over token texts.
    auto inLcsA = falses(ta.length);
    auto inLcsB = falses(tb.length);
    tokenLcs(aText, ta, bText, tb, inLcsA, inLcsB);

    size_t changedA = 0, changedB = 0;
    foreach (idx; 0 .. inLcsA.length)
        if (!inLcsA[idx])
            changedA++;
    foreach (idx; 0 .. inLcsB.length)
        if (!inLcsB[idx])
            changedB++;

    // Changed-ratio gate: a pair that mostly changed reads better as a
    // whole-row rewrite than as confetti.
    immutable total = ta.length + tb.length;
    if (total > 0
        && (cast(double)(changedA + changedB)) / total > opt.maxRefineChangedRatio)
    {
        oldRow.emphStart = cast(uint) emphArena.length;
        oldRow.emphCount = 1;
        emphArena ~= Span(0, aText.length);
        newRow.emphStart = cast(uint) emphArena.length;
        newRow.emphCount = 1;
        emphArena ~= Span(0, bText.length);
        return;
    }

    appendChangedSpans(oldRow, ta, inLcsA, emphArena);
    appendChangedSpans(newRow, tb, inLcsB, emphArena);
}

/**
`DVN4`: emphasize the changed CELLS of a paired table row.

Returns `false` — leaving the caller to fall back on word refinement — unless
both sides are pipe-table rows with the same cell count. A row that gained or
lost a column is a structural change that cell-wise emphasis would misrepresent.

Cells that differ get their whole span emphasized, padding included: the cell
is the unit the reviewer is being pointed at, and highlighting a fragment of it
would beg the question of which fragment.
*/
private bool refineTableRow(ref Row oldRow, scope const(char)[] aText,
    ref Row newRow, scope const(char)[] bText,
    ref SmallBuffer!Span emphArena) @safe pure nothrow @nogc
{
    SmallBuffer!Span ca, cb;
    const na = cellSpans(aText, ca);
    const nb = cellSpans(bText, cb);
    if (na == 0 || na != nb)
        return false;

    // A separator pair carries no content to point at: its cells are dashes.
    // Claiming "this cell changed" about a column-width redraw would be
    // exactly the noise this layer exists to remove.
    if (isSeparatorRow(aText) && isSeparatorRow(bText))
    {
        oldRow.emphCount = 0;
        newRow.emphCount = 0;
        return true;
    }

    const startA = emphArena.length;
    uint countA;
    foreach (i; 0 .. na)
    {
        const x = aText[ca[i].start .. ca[i].end];
        const y = bText[cb[i].start .. cb[i].end];
        if (cellsEqual(x, y))
            continue;
        emphArena ~= ca[i];
        ++countA;
    }
    oldRow.emphStart = cast(uint) startA;
    oldRow.emphCount = countA;

    const startB = emphArena.length;
    uint countB;
    foreach (i; 0 .. nb)
    {
        const x = aText[ca[i].start .. ca[i].end];
        const y = bText[cb[i].start .. cb[i].end];
        if (cellsEqual(x, y))
            continue;
        emphArena ~= cb[i];
        ++countB;
    }
    newRow.emphStart = cast(uint) startB;
    newRow.emphCount = countB;
    return true;
}

/// Refine every paired pair in `rows` (`Row.pair` indices are relative to
/// this slice, as `pairChangeBlocks` leaves them). `oldText`/`newText` back
/// the rows' `src` spans per side; spans land in `emphArena`.
void refineRows(scope Row[] rows, scope const(char)[] oldText,
    scope const(char)[] newText, ref SmallBuffer!Span emphArena,
    in DiffOptions opt) @safe pure nothrow @nogc
{
    foreach (idx, ref row; rows)
        if (row.kind == RowKind.removed && row.pair >= 0)
        {
            auto counterpart = &rows[cast(size_t) row.pair];
            refinePair(row, oldText[row.src.start .. row.src.end],
                *counterpart, newText[counterpart.src.start .. counterpart.src.end],
                emphArena, opt);
        }
}

private SmallBuffer!bool falses(size_t n) @safe pure nothrow @nogc
{
    SmallBuffer!bool b;
    b.reserve(n);
    foreach (_; 0 .. n)
        b ~= false;
    return b;
}

private void tokenLcs(scope const(char)[] aText, in SmallBuffer!Token ta,
    scope const(char)[] bText, in SmallBuffer!Token tb,
    ref SmallBuffer!bool inLcsA, ref SmallBuffer!bool inLcsB) @safe pure nothrow @nogc
{
    // Classic O(n·m) LCS table with backtrack, flat; sizes are capped by the
    // caller (`maxRefineTokens`).
    immutable n = ta.length, m = tb.length;
    immutable w = m + 1;
    SmallBuffer!uint tableBuf;
    tableBuf.reserve((n + 1) * w);
    foreach (_; 0 .. (n + 1) * w)
        tableBuf ~= 0u;
    scope table = tableBuf[];

    bool eq(size_t i, size_t j) @safe pure nothrow @nogc
        => aText[ta[i].start .. ta[i].end] == bText[tb[j].start .. tb[j].end];

    foreach (i; 0 .. n)
        foreach (j; 0 .. m)
        {
            immutable up = table[i * w + j + 1];
            immutable left = table[(i + 1) * w + j];
            table[(i + 1) * w + j + 1] = eq(i, j)
                ? table[i * w + j] + 1
                : (up > left ? up : left);
        }

    scope la = inLcsA[];
    scope lb = inLcsB[];
    size_t i = n, j = m;
    while (i > 0 && j > 0)
    {
        if (eq(i - 1, j - 1) && table[i * w + j] == table[(i - 1) * w + j - 1] + 1)
        {
            la[i - 1] = true;
            lb[j - 1] = true;
            i--;
            j--;
        }
        else if (table[(i - 1) * w + j] >= table[i * w + j - 1])
            i--;
        else
            j--;
    }
}

private void appendChangedSpans(ref Row row, in SmallBuffer!Token tokens,
    in SmallBuffer!bool inLcs, ref SmallBuffer!Span emphArena) @safe pure nothrow @nogc
{
    row.emphStart = cast(uint) emphArena.length;
    size_t idx = 0;
    uint count = 0;
    while (idx < tokens.length)
    {
        if (inLcs[idx])
        {
            idx++;
            continue;
        }
        immutable start = tokens[idx].start;
        size_t end = tokens[idx].end;
        idx++;
        while (idx < tokens.length && !inLcs[idx])
        {
            end = tokens[idx].end;
            idx++;
        }
        emphArena ~= Span(start, end - start);
        count++;
    }
    row.emphCount = count;
}

@("refine.tokenize.classes")
@safe pure nothrow @nogc
unittest
{
    auto t = tokenize("foo_bar = 42;");
    // foo_bar · space · = · space · 42 · ;
    assert(t.length == 6);
    assert(t[0].length == 7);
    assert(t[2].length == 1);
}

@("refine.tokenize.utf8-one-token")
@safe pure nothrow @nogc
unittest
{
    auto t = tokenize("a→b");
    assert(t.length == 3);
    assert(t[1].length == 3); // the 3-byte arrow stays one token
}

@("refine.refinePair.single-token-change")
@safe pure nothrow @nogc
unittest
{
    enum aText = "int total = compute(a, b);";
    enum bText = "int total = compute(a, c);";
    auto o = Row(RowKind.removed, 1, 0, Span(0, aText.length), 1);
    auto n = Row(RowKind.added, 0, 1, Span(0, bText.length), 0);
    SmallBuffer!Span arena;
    refinePair(o, aText, n, bText, arena, DiffOptions());
    assert(o.emphCount == 1);
    const so = arena[o.emphStart];
    assert(aText[so.start .. so.end] == "b");
    assert(n.emphCount == 1);
    const sn = arena[n.emphStart];
    assert(bText[sn.start .. sn.end] == "c");
}

@("refine.refinePair.ratio-gate-whole-row")
@safe pure nothrow @nogc
unittest
{
    enum aText = "alpha beta gamma";
    enum bText = "delta epsilon zeta eta";
    auto o = Row(RowKind.removed, 1, 0, Span(0, aText.length), 1);
    auto n = Row(RowKind.added, 0, 1, Span(0, bText.length), 0);
    SmallBuffer!Span arena;
    refinePair(o, aText, n, bText, arena, DiffOptions());
    assert(o.emphCount == 1 && arena[o.emphStart] == Span(0, aText.length));
    assert(n.emphCount == 1 && arena[n.emphStart] == Span(0, bText.length));
}

@("refine.refinePair.whitespace-run-localized")
@safe pure nothrow @nogc
unittest
{
    // A re-padded row: only the changed part should light up, not the whole
    // row. These are table rows, so `DVN4` refines them CELL-wise — the
    // emphasis covers the changed cell including its padding, because the
    // cell is the unit the reviewer is being pointed at. The property this
    // test has always asserted is unchanged: the unchanged column stays dark.
    enum aText = "| foo | bar |";
    enum bText = "| foo    | baz |";
    auto o = Row(RowKind.removed, 1, 0, Span(0, aText.length), 1);
    auto n = Row(RowKind.added, 0, 1, Span(0, bText.length), 0);
    SmallBuffer!Span arena;
    refinePair(o, aText, n, bText, arena, DiffOptions());

    assert(o.emphCount == 1, "one cell differs, so one span");
    const s = arena[o.emphStart];
    assert(stripped(aText[s.start .. s.end]) == "bar");
    // The `foo` column is untouched and must stay so — the padding it gained
    // on the other side is not a change to it.
    foreach (i; 0 .. o.emphCount)
    {
        const sp = arena[o.emphStart + i];
        assert(stripped(aText[sp.start .. sp.end]) != "foo");
    }

    // Word refinement is still what a non-table row gets.
    enum wa = "int a = compute(x, y);";
    enum wb = "int a = compute(x, z);";
    auto wo = Row(RowKind.removed, 1, 0, Span(0, wa.length), 1);
    auto wn = Row(RowKind.added, 0, 1, Span(0, wb.length), 0);
    SmallBuffer!Span warena;
    refinePair(wo, wa, wn, wb, warena, DiffOptions());
    bool marksY;
    foreach (i; 0 .. wo.emphCount)
        if (wa[warena[wo.emphStart + i].start .. warena[wo.emphStart + i].end] == "y")
            marksY = true;
    assert(marksY, "a token, not a cell, when the row is not a table row");
}

private const(char)[] stripped(return scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t a;
    while (a < s.length && (s[a] == ' ' || s[a] == '\t'))
        ++a;
    size_t b = s.length;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t'))
        --b;
    return s[a .. b];
}
