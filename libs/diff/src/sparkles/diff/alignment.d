/**
N-way line alignment (`DVM2`): any number of texts placed in rows against a
reference, for side-by-side panes with more than two sides, such as the
conflict view's ours · base · theirs (`CFV2`).

Each side is diffed against the reference with the two-way engine, so the
alignment inherits its pairing: a reference line and the side line it was
paired with share a row, a line the side deleted leaves a filler, and the
lines a side inserted before a reference line fill rows of their own,
lined up across sides by their order in that gap. That is Neovim's
linematch reduced to its useful case: one reference, every other side
aligned to it.
*/
module sparkles.diff.alignment;

import sparkles.base.buffer : SharedBuffer;
import sparkles.diff.engine : diffText;
import sparkles.diff.model : DiffDoc, DiffOptions, RowKind;

/// The most sides one alignment holds, the reference included.
enum size_t maxAlignSides = 4;

/// One row: a 0-based line index per side, `-1` for a filler. Side 0 is the
/// reference.
struct AlignedRow
{
    int[maxAlignSides] at = -1;
}

/**
Aligns `sides` to `reference` into `rows` (`DVM2`): row `r`'s `at[0]` is a
reference line or `-1`, and `at[1 + i]` the matching line of `sides[i]`.
*/
void alignSides(scope const(char)[] reference, scope const(char[])[] sides,
    ref SharedBuffer!(AlignedRow, 16) rows, in DiffOptions options = DiffOptions.init)
    @safe pure nothrow @nogc
in (sides.length < maxAlignSides, "too many sides to align")
{
    // Every reference line appears as a row of a whole-file diff, so each
    // side's walk sees all of them: the line each maps to (or -1), and the
    // side lines inserted before each.
    DiffOptions whole = options;
    whole.context = uint.max;
    const refLines = lineCount(reference);
    SharedBuffer!(int, 64)[maxAlignSides - 1] matchOf;
    SharedBuffer!(uint, 64)[maxAlignSides - 1] insertedBefore; // (reference line, side line) pairs
    foreach (s, side; sides)
    {
        foreach (_; 0 .. refLines)
            matchOf[s].put(-1);
        if (reference == side)
        {
            foreach (r; 0 .. refLines)
                matchOf[s][r] = cast(int) r;
            continue;
        }
        const doc = diffText(reference, side, "a", "b", whole);
        foreach (ref h; doc.hunks[])
        {
            const rowsOf = doc.hunkRows(h);
            foreach (i, ref row; rowsOf)
            {
                final switch (row.kind)
                {
                    case RowKind.context:
                        matchOf[s][row.oldLine - 1] = row.newLine - 1;
                        break;
                    case RowKind.removed:
                        if (row.pair >= 0)
                            matchOf[s][row.oldLine - 1] = rowsOf[row.pair].newLine - 1;
                        break;
                    case RowKind.added:
                        if (!pairedFrom(rowsOf, i))
                        {
                            insertedBefore[s].put(followingRef(rowsOf, i, cast(uint) refLines));
                            insertedBefore[s].put(row.newLine - 1);
                        }
                        break;
                }
            }
        }
    }

    foreach (r; 0 .. refLines + 1)
    {
        // The insertions before reference line `r`, side by side.
        size_t most;
        foreach (s; 0 .. sides.length)
            most = max(most, countBefore(insertedBefore[s], cast(uint) r));
        foreach (k; 0 .. most)
        {
            AlignedRow row;
            foreach (s; 0 .. sides.length)
                row.at[1 + s] = nthBefore(insertedBefore[s], cast(uint) r, k);
            rows.put(row);
        }
        if (r == refLines)
            break;
        AlignedRow row;
        row.at[0] = cast(int) r;
        foreach (s; 0 .. sides.length)
            row.at[1 + s] = matchOf[s][r];
        rows.put(row);
    }
}

private size_t max(size_t a, size_t b) @safe pure nothrow @nogc => a > b ? a : b;

/// The number of lines in `text`, a final line without a break counted.
private size_t lineCount(scope const(char)[] text) @safe pure nothrow @nogc
{
    size_t n;
    foreach (c; text)
        n += c == '\n';
    return text.length && text[$ - 1] != '\n' ? n + 1 : n;
}

/// Whether added row `i` is some removed row's pair.
private bool pairedFrom(T)(scope T rows, size_t i) @safe pure nothrow @nogc
{
    foreach (ref r; rows)
        if (r.kind == RowKind.removed && r.pair == cast(int) i)
            return true;
    return false;
}

/// The 0-based reference line an insertion at row `i` comes before: the
/// next removed or context row's, else the end.
private uint followingRef(T)(scope T rows, size_t i, uint end) @safe pure nothrow @nogc
{
    foreach (ref r; rows[i + 1 .. $])
        if (r.kind != RowKind.added)
            return r.oldLine - 1;
    return end;
}

/// How many side lines are inserted before reference line `r`.
private size_t countBefore(ref SharedBuffer!(uint, 64) pairs, uint r) @safe pure nothrow @nogc
{
    size_t n;
    for (size_t i = 0; i + 1 < pairs.length; i += 2)
        n += pairs[i] == r;
    return n;
}

/// The `k`th side line inserted before reference line `r`, or -1.
private int nthBefore(ref SharedBuffer!(uint, 64) pairs, uint r, size_t k) @safe pure nothrow @nogc
{
    for (size_t i = 0; i + 1 < pairs.length; i += 2)
        if (pairs[i] == r && k-- == 0)
            return cast(int) pairs[i + 1];
    return -1;
}

@("alignment.alignSides.threeWay")
@safe pure nothrow @nogc
unittest
{
    // base: a b c d · ours changes b, inserts x before d · theirs drops c.
    SharedBuffer!(AlignedRow, 16) rows;
    const(char[])[2] sides = ["a\nint b = 2;\nc\nx\nd\n", "a\nint b = 1;\nd\n"];
    alignSides("a\nint b = 1;\nc\nd\n", sides[], rows);
    // a | a | a ; b | B | b ; c | c | - ; - | x | - ; d | d | d
    assert(rows.length == 5);
    assert(rows[0].at[0 .. 3] == [0, 0, 0]);
    assert(rows[1].at[0 .. 3] == [1, 1, 1], "a changed line shares the reference's row");
    assert(rows[2].at[0 .. 3] == [2, 2, -1], "theirs deleted c");
    assert(rows[3].at[0 .. 3] == [-1, 3, -1], "ours inserted x");
    assert(rows[4].at[0 .. 3] == [3, 4, 2]);
}

@("alignment.alignSides.insertionsLineUpAcrossSides")
@safe pure nothrow @nogc
unittest
{
    SharedBuffer!(AlignedRow, 16) rows;
    const(char[])[2] sides = ["a\nx\ny\nz\n", "a\nq\nz\n"];
    alignSides("a\nz\n", sides[], rows);
    // a ; (x, q) ; (y, -) ; z
    assert(rows.length == 4);
    assert(rows[1].at[0 .. 3] == [-1, 1, 1] && rows[2].at[0 .. 3] == [-1, 2, -1]);
    assert(rows[3].at[0 .. 3] == [1, 3, 2]);
}
