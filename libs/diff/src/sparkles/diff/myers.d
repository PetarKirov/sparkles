/// The line-level diff core (`DVM1`): Myers' O(ND) greedy algorithm over
/// interned line ids, with a common prefix/suffix trim, an edit-distance cap
/// that degrades to one remove+add block (`DVM6`), git-style change-block row
/// emission (all removals, then all additions), and hunk extraction.
///
/// Everything here is `@nogc` (`DVM8`): lines are `Span`s into the input,
/// working storage is `SmallBuffer` (interning is sort-based, not an AA),
/// hunks are index ranges into the one row arena, and hot loops index
/// through once-taken slices so the copy-on-write uniqueness check runs per
/// pass, not per element.
module sparkles.diff.myers;

import std.algorithm.sorting : sort;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.diff.model : Degradation, DiffOptions, Hunk, Row, RowKind, Span;
import sparkles.diff.normalize : compareLines, linesEqual, WhitespaceMode;

/// The line list of one side — spans into that side's text.
alias LineSpans = SmallBuffer!Span;

/// Split `text` into line spans without their trailing newline.
/// `missingNewline` reports whether the last line lacked one (the
/// `\ No newline at end of file` case). An empty text has zero lines.
LineSpans splitDiffLines(scope const(char)[] text, out bool missingNewline)
    @safe pure nothrow @nogc
{
    missingNewline = false;
    LineSpans lines;
    if (text.length == 0)
        return lines;
    size_t start = 0;
    foreach (i, c; text)
        if (c == '\n')
        {
            lines ~= Span(start, i - start);
            start = i + 1;
        }
    if (start < text.length)
    {
        lines ~= Span(start, text.length - start);
        missingNewline = true;
    }
    return lines;
}

@("myers.splitDiffLines.basic")
@safe pure nothrow @nogc
unittest
{
    bool missing;
    enum text = "a\nb\n";
    auto ab = splitDiffLines(text, missing);
    assert(ab.length == 2);
    assert(text[ab[0].start .. ab[0].end] == "a");
    assert(text[ab[1].start .. ab[1].end] == "b");
    assert(!missing);
    auto noNl = splitDiffLines("a\nb", missing);
    assert(noNl.length == 2 && missing);
    assert(splitDiffLines("", missing).empty);
    assert(!missing);
    auto one = splitDiffLines("\n", missing);
    assert(one.length == 1 && one[0].length == 0);
    assert(!missing);
}

/// Intern both sides' lines through ONE vocabulary so the Myers inner loop
/// compares integers. Sort-based (`@nogc` — no AA): indices sorted by line
/// content, equal runs share an id.
private void internLinePair(
    scope const(char)[] oldText, in LineSpans oldLines,
    scope const(char)[] newText, in LineSpans newLines,
    ref SmallBuffer!uint oldIds, ref SmallBuffer!uint newIds,
    WhitespaceMode ws = WhitespaceMode.exact) @safe pure nothrow @nogc
{
    static struct Key
    {
        Span span;
        size_t idx; // < oldLines.length ⇒ old side
    }

    const total = oldLines.length + newLines.length;
    SmallBuffer!Key keys;
    keys.reserve(total);
    foreach (i; 0 .. oldLines.length)
        keys ~= Key(oldLines[i], i);
    foreach (i; 0 .. newLines.length)
        keys ~= Key(newLines[i], oldLines.length + i);

    const(char)[] lineOf(in Key k) @safe pure nothrow @nogc
        => k.idx < oldLines.length
            ? oldText[k.span.start .. k.span.end]
            : newText[k.span.start .. k.span.end];

    // `DVN1`: one comparison decides both the sort order and the grouping
    // below, so a whitespace policy cannot make the two disagree.
    sort!((in a, in b) => compareLines(lineOf(a), lineOf(b), ws) < 0)(keys[]);

    oldIds.clear();
    oldIds.reserve(oldLines.length);
    foreach (_; 0 .. oldLines.length)
        oldIds ~= 0u;
    newIds.clear();
    newIds.reserve(newLines.length);
    foreach (_; 0 .. newLines.length)
        newIds ~= 0u;

    scope oldSlice = oldIds[];
    scope newSlice = newIds[];
    scope sorted = keys[];
    uint id = 0;
    foreach (i; 0 .. sorted.length)
    {
        if (i != 0 && !linesEqual(lineOf(sorted[i - 1]), lineOf(sorted[i]), ws))
            id++;
        if (sorted[i].idx < oldLines.length)
            oldSlice[sorted[i].idx] = id;
        else
            newSlice[sorted[i].idx - oldLines.length] = id;
    }
}

/// The result of the line diff proper: which old lines are removed and which
/// new lines are inserted, plus whether the search was capped.
struct LineDiff
{
    SmallBuffer!bool oldRemoved;
    SmallBuffer!bool newInserted;
    Degradation degraded;
}

private SmallBuffer!bool falses(size_t n) @safe pure nothrow @nogc
{
    SmallBuffer!bool b;
    b.reserve(n);
    foreach (_; 0 .. n)
        b ~= false;
    return b;
}

/// Diff two interned sequences. On a capped search the changed middle
/// (after prefix/suffix trim) is marked wholly removed+inserted.
LineDiff diffLineIds(scope const(uint)[] a, scope const(uint)[] b,
    uint maxEditDistance) @safe pure nothrow @nogc
{
    auto res = LineDiff(falses(a.length), falses(b.length));
    scope oldRemoved = res.oldRemoved[];
    scope newInserted = res.newInserted[];

    // Common prefix / suffix trim.
    size_t pre = 0;
    while (pre < a.length && pre < b.length && a[pre] == b[pre])
        pre++;
    size_t endA = a.length, endB = b.length;
    while (endA > pre && endB > pre && a[endA - 1] == b[endB - 1])
    {
        endA--;
        endB--;
    }
    auto ac = a[pre .. endA], bc = b[pre .. endB];
    immutable n = cast(ptrdiff_t) ac.length, m = cast(ptrdiff_t) bc.length;

    void degradeMiddle() @safe
    {
        oldRemoved[pre .. endA] = true;
        newInserted[pre .. endB] = true;
        res.degraded = Degradation.editDistanceCapped;
    }

    if (n == 0 && m == 0)
        return res;
    if (n == 0)
    {
        newInserted[pre .. endB] = true;
        return res;
    }
    if (m == 0)
    {
        oldRemoved[pre .. endA] = true;
        return res;
    }

    immutable ptrdiff_t maxD = {
        auto cap = cast(ptrdiff_t) maxEditDistance;
        return cap < n + m ? cap : n + m;
    }();
    immutable off = maxD;
    immutable stride = 2 * maxD + 1;

    SmallBuffer!ptrdiff_t vBuf;
    vBuf.reserve(stride);
    foreach (_; 0 .. stride)
        vBuf ~= 0;
    scope v = vBuf[];

    // The per-d V snapshots, flattened (`trace[d * stride + off + k]`).
    SmallBuffer!ptrdiff_t trace;
    ptrdiff_t dFound = -1;

    outer: foreach (d; 0 .. maxD + 1)
    {
        trace ~= vBuf[];
        for (ptrdiff_t k = -d; k <= d; k += 2)
        {
            ptrdiff_t x;
            if (k == -d || (k != d && v[off + k - 1] < v[off + k + 1]))
                x = v[off + k + 1];
            else
                x = v[off + k - 1] + 1;
            ptrdiff_t y = x - k;
            while (x < n && y < m && ac[x] == bc[y])
            {
                x++;
                y++;
            }
            v[off + k] = x;
            if (x >= n && y >= m)
            {
                dFound = d;
                break outer;
            }
        }
    }

    if (dFound < 0)
    {
        degradeMiddle();
        return res;
    }

    // Backtrack: mark one removal or insertion per d step.
    scope tr = trace[];
    ptrdiff_t x = n, y = m;
    for (ptrdiff_t d = dFound; d > 0; d--)
    {
        scope vprev = tr[d * stride .. (d + 1) * stride];
        immutable k = x - y;
        ptrdiff_t prevK;
        if (k == -d || (k != d && vprev[off + k - 1] < vprev[off + k + 1]))
            prevK = k + 1;
        else
            prevK = k - 1;
        immutable prevX = vprev[off + prevK];
        immutable prevY = prevX - prevK;
        while (x > prevX && y > prevY)
        {
            x--;
            y--;
        }
        if (x == prevX)
            newInserted[pre + --y] = true;
        else
            oldRemoved[pre + --x] = true;
        assert(x == prevX && y == prevY);
    }
    return res;
}

/// Emit the full row stream git-style: within a change block, all removed
/// rows precede all added rows; line numbers are 1-based per side. Row `src`
/// spans reference each side's own text (the `Row.src` convention).
SmallBuffer!Row buildRows(in LineSpans oldLines, in LineSpans newLines, in LineDiff d)
    @safe pure nothrow @nogc
{
    SmallBuffer!Row rows;
    rows.reserve(oldLines.length + newLines.length);
    scope oldRemoved = d.oldRemoved[];
    scope newInserted = d.newInserted[];
    size_t i = 0, j = 0;
    while (i < oldLines.length || j < newLines.length)
    {
        if ((i < oldLines.length && oldRemoved[i])
            || (j < newLines.length && newInserted[j]))
        {
            while (i < oldLines.length && oldRemoved[i])
            {
                rows ~= Row(RowKind.removed, cast(uint)(i + 1), 0, oldLines[i]);
                i++;
            }
            while (j < newLines.length && newInserted[j])
            {
                rows ~= Row(RowKind.added, 0, cast(uint)(j + 1), newLines[j]);
                j++;
            }
        }
        else
        {
            rows ~= Row(RowKind.context, cast(uint)(i + 1), cast(uint)(j + 1),
                oldLines[i]);
            i++;
            j++;
        }
    }
    return rows;
}

/// Group a full row stream into hunks with `context` context lines; change
/// blocks closer than `2 * context` merge into one hunk. Hunks are index
/// ranges into `rows` — no row is copied.
SmallBuffer!Hunk buildHunks(in SmallBuffer!Row rows, uint context) @safe pure nothrow @nogc
{
    // Indices of non-context rows.
    SmallBuffer!size_t changed;
    foreach (idx; 0 .. rows.length)
        if (rows[idx].kind != RowKind.context)
            changed ~= idx;
    SmallBuffer!Hunk hunks;
    if (changed.length == 0)
        return hunks;

    size_t blockStart = 0;
    while (blockStart < changed.length)
    {
        // Extend the block while gaps stay within 2*context.
        size_t blockEnd = blockStart;
        while (blockEnd + 1 < changed.length
            && changed[blockEnd + 1] - changed[blockEnd] <= 2 * context + 1)
            blockEnd++;

        immutable first = changed[blockStart] >= context ? changed[blockStart] - context : 0;
        immutable last = {
            auto l = changed[blockEnd] + context;
            return l < rows.length ? l : rows.length - 1;
        }();

        Hunk h;
        h.rowsStart = cast(uint) first;
        h.rowsCount = cast(uint)(last + 1 - first);
        foreach (r; first .. last + 1)
        {
            if (rows[r].oldLine != 0)
            {
                if (h.oldStart == 0)
                    h.oldStart = rows[r].oldLine;
                h.oldCount++;
            }
            if (rows[r].newLine != 0)
            {
                if (h.newStart == 0)
                    h.newStart = rows[r].newLine;
                h.newCount++;
            }
        }
        // Unified convention for an empty side: start is the line *before*
        // the insertion point (0 when inserting at the very top).
        if (h.oldCount == 0)
            h.oldStart = firstNeighborLine(rows, first, true);
        if (h.newCount == 0)
            h.newStart = firstNeighborLine(rows, first, false);
        hunks ~= h;
        blockStart = blockEnd + 1;
    }
    return hunks;
}

private uint firstNeighborLine(in SmallBuffer!Row rows, size_t firstIdx, bool oldSide)
    @safe pure nothrow @nogc
{
    // The last line number of the given side at or before the hunk start.
    foreach_reverse (idx; 0 .. firstIdx + 1)
    {
        immutable line = oldSide ? rows[idx].oldLine : rows[idx].newLine;
        if (line != 0 && idx < firstIdx)
            return line;
    }
    return 0;
}

/// Convenience: intern + diff in one call.
LineDiff diffLines(
    scope const(char)[] oldText, in LineSpans oldLines,
    scope const(char)[] newText, in LineSpans newLines,
    uint maxEditDistance, WhitespaceMode ws = WhitespaceMode.exact)
    @safe pure nothrow @nogc
{
    SmallBuffer!uint oldIds, newIds;
    internLinePair(oldText, oldLines, newText, newLines, oldIds, newIds, ws);
    return diffLineIds(oldIds[], newIds[], maxEditDistance);
}

@("myers.diffLineIds.reconstruction")
@safe pure
unittest
{
    // Property: context+removed reconstructs old; context+added reconstructs
    // new — over a deterministic pseudo-random corpus. (The test itself uses
    // GC arrays for brevity; the code under test is @nogc.)
    uint seed = 0xC0FFEE;
    uint next()
    {
        seed = seed * 1_664_525 + 1_013_904_223;
        return seed >> 16;
    }

    foreach (round; 0 .. 50)
    {
        uint[] a, b;
        foreach (_; 0 .. next() % 40)
            a ~= next() % 8;
        // Mutate a into b.
        b = a.dup;
        foreach (_; 0 .. next() % 10)
        {
            if (b.length == 0)
            {
                b ~= next() % 8;
                continue;
            }
            final switch (next() % 3)
            {
            case 0:
                b[next() % b.length] = next() % 8;
                break;
            case 1:
                immutable at = next() % (b.length + 1);
                b = b[0 .. at] ~ (next() % 8) ~ b[at .. $];
                break;
            case 2:
                immutable at = next() % b.length;
                b = b[0 .. at] ~ b[at + 1 .. $];
                break;
            }
        }

        auto d = diffLineIds(a, b, 1024);
        uint[] oldBack, newBack;
        foreach (i, id; a)
            if (!d.oldRemoved[i])
                oldBack ~= id;
        foreach (j, id; b)
            if (!d.newInserted[j])
                newBack ~= id;
        // The kept (context) sequences must be identical — they are the LCS.
        assert(oldBack == newBack);
        // And every input element is accounted for exactly once by kind.
        assert(d.oldRemoved.length == a.length);
        assert(d.newInserted.length == b.length);
    }
}

@("myers.diffLineIds.identical-and-empty")
@safe pure nothrow @nogc
unittest
{
    auto d = diffLineIds([1u, 2, 3], [1u, 2, 3], 64);
    assert(!d.oldRemoved[0] && !d.oldRemoved[1] && !d.oldRemoved[2]);
    assert(!d.newInserted[0] && !d.newInserted[1] && !d.newInserted[2]);
    assert(diffLineIds(null, null, 64).degraded == Degradation.none);
    auto ins = diffLineIds(null, [7u], 64);
    assert(ins.newInserted.length == 1 && ins.newInserted[0]);
}

@("myers.diffLineIds.capped-degrades")
@safe pure nothrow @nogc
unittest
{
    // With a cap of 1, a 2-edit diff must degrade, not fail.
    auto d = diffLineIds([1u, 2], [3u, 4], 1);
    assert(d.degraded == Degradation.editDistanceCapped);
    assert(d.oldRemoved[0] && d.oldRemoved[1]);
    assert(d.newInserted[0] && d.newInserted[1]);
}

@("myers.buildRows.git-style-grouping")
@safe pure nothrow @nogc
unittest
{
    bool missing;
    enum oldText = "a\nb\nc\nd\n";
    enum newText = "a\nx\ny\nd\n";
    auto o = splitDiffLines(oldText, missing);
    auto n = splitDiffLines(newText, missing);
    auto d = diffLines(oldText, o, newText, n, 64);
    auto rows = buildRows(o, n, d);
    const(char)[] textOf(in Row r) @safe pure nothrow @nogc
        => (r.kind == RowKind.added ? newText : oldText)[r.src.start .. r.src.end];

    assert(rows.length == 6);
    assert(rows[0].kind == RowKind.context && textOf(rows[0]) == "a");
    assert(rows[1].kind == RowKind.removed && textOf(rows[1]) == "b");
    assert(rows[2].kind == RowKind.removed && textOf(rows[2]) == "c");
    assert(rows[3].kind == RowKind.added && textOf(rows[3]) == "x");
    assert(rows[4].kind == RowKind.added && textOf(rows[4]) == "y");
    assert(rows[5].kind == RowKind.context && textOf(rows[5]) == "d");
    assert(rows[1].oldLine == 2 && rows[1].newLine == 0);
    assert(rows[3].oldLine == 0 && rows[3].newLine == 2);
}

@("myers.buildHunks.context-and-merge")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!Row rows;
    foreach (i; 0 .. 5)
        rows ~= Row(RowKind.context, cast(uint)(i + 1), cast(uint)(i + 1), Span(0, 1));
    rows ~= Row(RowKind.removed, 6, 0, Span(0, 3));
    rows ~= Row(RowKind.added, 0, 6, Span(0, 3));
    foreach (i; 6 .. 11)
        rows ~= Row(RowKind.context, cast(uint)(i + 1), cast(uint)(i + 2), Span(0, 1));

    auto hunks = buildHunks(rows, 2);
    assert(hunks.length == 1);
    assert(hunks[0].rowsCount == 6); // 2 ctx + rem + add + 2 ctx
    assert(hunks[0].rowsStart == 3);
    assert(hunks[0].oldStart == 4 && hunks[0].oldCount == 5);
    assert(hunks[0].newStart == 4 && hunks[0].newCount == 5);
}
