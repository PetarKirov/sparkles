/// The similarity alignment-pairing pass (`DVM2`): within each change block
/// (a run of removed rows followed by added rows), pair each removed line
/// with its most similar added line by dynamic programming — the Neovim
/// linematch / delta precedent — so side-by-side rows align and word
/// refinement compares the right lines. Pairing is monotonic (pairs never
/// cross) and gated by a similarity floor, block-size cap, and per-line
/// length cap (`DVM6`). `@nogc` throughout (`DVM8`): flat `SmallBuffer` DP
/// tables, sliced once per pass.
module sparkles.diff.pairing;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.diff.model : DiffOptions, Row, RowKind;

/// Normalized similarity of two lines in [0, 1]:
/// `2 * LCS(a, b) / (a.length + b.length)`, computed on at most `cap` bytes
/// per side (longer lines compare by prefix — a deliberate guard, not a bug).
double lineSimilarity(scope const(char)[] a, scope const(char)[] b, size_t cap)
    @safe pure nothrow @nogc
{
    if (a.length > cap)
        a = a[0 .. cap];
    if (b.length > cap)
        b = b[0 .. cap];
    if (a.length == 0 && b.length == 0)
        return 1.0;
    if (a.length == 0 || b.length == 0)
        return 0.0;
    immutable lcs = lcsLength(a, b);
    return (2.0 * lcs) / (a.length + b.length);
}

/// Byte-wise LCS length via the classic DP with two rolling rows.
private size_t lcsLength(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    SmallBuffer!size_t rowsBuf;
    immutable w = b.length + 1;
    rowsBuf.reserve(2 * w);
    foreach (_; 0 .. 2 * w)
        rowsBuf ~= 0;
    scope rows = rowsBuf[];

    size_t prevBase = 0, currBase = w;
    foreach (i; 0 .. a.length)
    {
        foreach (j; 0 .. b.length)
        {
            immutable up = rows[prevBase + j + 1];
            immutable left = rows[currBase + j];
            rows[currBase + j + 1] = a[i] == b[j]
                ? rows[prevBase + j] + 1
                : (up > left ? up : left);
        }
        immutable t = prevBase;
        prevBase = currBase;
        currBase = t;
        rows[currBase .. currBase + w] = 0;
    }
    return rows[prevBase + b.length];
}

/// Pair rows within every change block of `rows` (one hunk's row slice —
/// `Row.pair` indices are relative to the passed slice, i.e. hunk-relative).
/// `oldText`/`newText` back the rows' `src` spans per side.
void pairChangeBlocks(scope Row[] rows, scope const(char)[] oldText,
    scope const(char)[] newText, in DiffOptions opt) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < rows.length)
    {
        if (rows[i].kind != RowKind.removed)
        {
            i++;
            continue;
        }
        // A change block: removed run, then added run (buildRows guarantees
        // the order).
        size_t remStart = i;
        while (i < rows.length && rows[i].kind == RowKind.removed)
            i++;
        size_t addStart = i;
        while (i < rows.length && rows[i].kind == RowKind.added)
            i++;
        pairBlock(rows, oldText, newText, remStart, addStart - remStart,
            addStart, i - addStart, opt);
    }
}

private void pairBlock(scope Row[] rows, scope const(char)[] oldText,
    scope const(char)[] newText, size_t remStart, size_t remLen,
    size_t addStart, size_t addLen, in DiffOptions opt) @safe pure nothrow @nogc
{
    if (remLen == 0 || addLen == 0)
        return;
    if (remLen > opt.maxBlockRows || addLen > opt.maxBlockRows)
        return; // guard: huge blocks stay unpaired

    const(char)[] remText(size_t r) @safe pure nothrow @nogc
        => oldText[rows[remStart + r].src.start .. rows[remStart + r].src.end];
    const(char)[] addText(size_t c) @safe pure nothrow @nogc
        => newText[rows[addStart + c].src.start .. rows[addStart + c].src.end];

    // Alignment DP maximizing total similarity; a pair below the floor is
    // not allowed (scores as a gap). Both tables are flat buffers.
    SmallBuffer!double simBuf;
    simBuf.reserve(remLen * addLen);
    foreach (r; 0 .. remLen)
        foreach (c; 0 .. addLen)
        {
            immutable s = lineSimilarity(remText(r), addText(c), opt.maxPairLineLength);
            simBuf ~= s >= opt.minPairSimilarity ? s : -1.0;
        }
    scope sim = simBuf[];

    // score[r][c] = best over first r removed / first c added.
    immutable sw = addLen + 1;
    SmallBuffer!double scoreBuf;
    scoreBuf.reserve((remLen + 1) * sw);
    foreach (_; 0 .. (remLen + 1) * sw)
        scoreBuf ~= 0.0;
    scope score = scoreBuf[];

    foreach (r; 1 .. remLen + 1)
        foreach (c; 1 .. addLen + 1)
        {
            immutable up = score[(r - 1) * sw + c];
            immutable left = score[r * sw + c - 1];
            double best = up > left ? up : left;
            immutable s = sim[(r - 1) * addLen + c - 1];
            if (s >= 0 && score[(r - 1) * sw + c - 1] + s > best)
                best = score[(r - 1) * sw + c - 1] + s;
            score[r * sw + c] = best;
        }

    // Backtrack.
    size_t r = remLen, c = addLen;
    while (r > 0 && c > 0)
    {
        immutable s = sim[(r - 1) * addLen + c - 1];
        if (s >= 0 && score[r * sw + c] == score[(r - 1) * sw + c - 1] + s)
        {
            rows[remStart + r - 1].pair = cast(int)(addStart + c - 1);
            rows[addStart + c - 1].pair = cast(int)(remStart + r - 1);
            r--;
            c--;
        }
        else if (score[r * sw + c] == score[(r - 1) * sw + c])
            r--;
        else
            c--;
    }
}

@("pairing.lineSimilarity.basics")
@safe pure nothrow @nogc
unittest
{
    assert(lineSimilarity("abc", "abc", 400) == 1.0);
    assert(lineSimilarity("", "", 400) == 1.0);
    assert(lineSimilarity("abc", "", 400) == 0.0);
    assert(lineSimilarity("abcd", "abxd", 400) > 0.7);
    assert(lineSimilarity("abcd", "wxyz", 400) == 0.0);
}

version (unittest)
{
    import sparkles.diff.model : Span;

    /// Test scaffolding: rows over two side texts, spans covering each line.
    private Row rowOf(RowKind kind, uint oldLine, uint newLine, Span src)
        @safe pure nothrow @nogc
        => Row(kind, oldLine, newLine, src);
}

@("pairing.pairChangeBlocks.similar-lines-pair")
@safe pure nothrow @nogc
unittest
{
    enum oldText = "int total = compute(a, b);\ncompletely different line\n";
    enum newText = "int total = compute(a, b, c);\n";
    Row[3] rows = [
        rowOf(RowKind.removed, 1, 0, Span(0, 26)),
        rowOf(RowKind.removed, 2, 0, Span(27, 25)),
        rowOf(RowKind.added, 0, 1, Span(0, 29)),
    ];
    pairChangeBlocks(rows[], oldText, newText, DiffOptions());
    assert(rows[0].pair == 2);
    assert(rows[2].pair == 0);
    assert(rows[1].pair == -1);
}

@("pairing.pairChangeBlocks.monotonic-no-crossing")
@safe pure nothrow @nogc
unittest
{
    // Both removed lines resemble both added lines; pairing must stay
    // monotonic: 0→2 and 1→3, never 0→3 with 1→2.
    enum oldText = "alpha beta gamma one\nalpha beta gamma two\n";
    enum newText = "alpha beta gamma one!\nalpha beta gamma two!\n";
    Row[4] rows = [
        rowOf(RowKind.removed, 1, 0, Span(0, 20)),
        rowOf(RowKind.removed, 2, 0, Span(21, 20)),
        rowOf(RowKind.added, 0, 1, Span(0, 21)),
        rowOf(RowKind.added, 0, 2, Span(22, 21)),
    ];
    pairChangeBlocks(rows[], oldText, newText, DiffOptions());
    assert(rows[0].pair == 2);
    assert(rows[1].pair == 3);
}

@("pairing.pairChangeBlocks.dissimilar-stay-unpaired")
@safe pure nothrow @nogc
unittest
{
    enum oldText = "aaaaaaaaaaaa\n";
    enum newText = "zzzzzzzzzzzz\n";
    Row[2] rows = [
        rowOf(RowKind.removed, 1, 0, Span(0, 12)),
        rowOf(RowKind.added, 0, 1, Span(0, 12)),
    ];
    pairChangeBlocks(rows[], oldText, newText, DiffOptions());
    assert(rows[0].pair == -1 && rows[1].pair == -1);
}

@("pairing.pairChangeBlocks.block-cap-guard")
@safe pure nothrow @nogc
unittest
{
    DiffOptions opt;
    opt.maxBlockRows = 1;
    enum text = "same line\nsame line\n";
    Row[4] rows = [
        rowOf(RowKind.removed, 1, 0, Span(0, 9)),
        rowOf(RowKind.removed, 2, 0, Span(10, 9)),
        rowOf(RowKind.added, 0, 1, Span(0, 9)),
        rowOf(RowKind.added, 0, 2, Span(10, 9)),
    ];
    pairChangeBlocks(rows[], text, text, opt);
    assert(rows[0].pair == -1); // guard left the oversized block unpaired
}
