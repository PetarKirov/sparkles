// The opt-in structural view (`DVN3`): intra-line emphasis whose boundaries
// come from the grammar instead of from word/space classes.
//
// Word refinement asks "which character runs differ". The grammar asks a
// better question — "which TOKENS differ" — and the two disagree in ways a
// reviewer feels. `return a+b;` → `return a - b;` refines to a single blurry
// run across `a+b`, because whitespace changed on both sides of the operator;
// tokenized, it is exactly one changed token, `+` → `-`. `foo.barBaz()` →
// `foo.barQux()` refines by word run and lights up the whole identifier
// either way, but `x = 1` → `x  =  1` lights up NOTHING here, because the
// grammar has no token for the padding.
//
// The pass reuses `sparkles:diff`'s LCS, changed-ratio gate and span emission
// through `refinePairTokens` — the engine stays tree-sitter-free (decision 5)
// and merely stops assuming it knows where tokens begin.
module diff_token_view;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.diff : DiffDoc, DiffOptions, FileEntry, RefineToken, Row,
    RowKind, refinePairTokens;

import diff_structural : Token;

/**
Rewrites one file's paired-row emphasis from the two token streams.

`oldSide`/`newSide` are the file's full texts — the ones the tokens index,
which for a patch-sourced document are NOT the document's backing texts. Rows
are located by line number and verified byte-for-byte against the side text
before anything is rewritten, so a document whose sides were reconstructed
from a stale worktree degrades to keeping its word-level emphasis instead of
pointing at the wrong bytes.

Returns the number of row pairs re-emphasized.
*/
size_t applyTokenEmphasis(ref DiffDoc doc, in FileEntry file,
    scope const(char)[] oldSide, scope const(char)[] newSide,
    scope const(Token)[] oldTokens, scope const(Token)[] newTokens,
    in DiffOptions opt) @safe
{
    if (oldSide.length == 0 || newSide.length == 0)
        return 0;
    const oldLines = lineStarts(oldSide);
    const newLines = lineStarts(newSide);

    size_t done;
    foreach (hi; file.hunksStart .. file.hunksStart + file.hunksCount)
    {
        const hunk = doc.hunks[hi];
        foreach (ri; hunk.rowsStart .. hunk.rowsStart + hunk.rowsCount)
        {
            const row = doc.rows[ri];
            if (row.kind != RowKind.removed || row.pair < 0)
                continue;
            const pairIndex = hunk.rowsStart + cast(size_t) row.pair;
            if (pairIndex >= doc.rows.length)
                continue;
            const mate = doc.rows[pairIndex];

            // The rows must be the lines the tokens were taken from.
            const a = lineAt(oldSide, oldLines, row.oldLine);
            const b = lineAt(newSide, newLines, mate.newLine);
            if (a is null || b is null
                || a != doc.rowText(row) || b != doc.rowText(mate))
                continue;

            SmallBuffer!RefineToken ta, tb;
            tokensOnLine(oldTokens, oldSide, oldLines, row.oldLine, ta);
            tokensOnLine(newTokens, newSide, newLines, mate.newLine, tb);

            // Clear first: `refinePairTokens` leaves a guarded pair untouched,
            // and keeping word-level spans for some rows and token-level ones
            // for others would render as one incoherent view.
            Row oldRow = row;
            Row newRow = mate;
            oldRow.emphCount = 0;
            newRow.emphCount = 0;
            refinePairTokens(oldRow, a, ta, newRow, b, tb, doc.emph, opt);
            doc.rows[ri] = oldRow;
            doc.rows[pairIndex] = newRow;
            ++done;
        }
    }
    return done;
}

/// The tokens overlapping 1-based `line`, clipped to it and rebased to
/// line-relative offsets — the coordinates `Row` emphasis spans use.
private void tokensOnLine(scope const(Token)[] toks, scope const(char)[] source,
    scope const(size_t)[] starts, uint line, ref SmallBuffer!RefineToken sink)
    @safe
{
    if (line == 0 || line > starts.length)
        return;
    const row = line - 1;
    const lineStart = starts[row];
    const lineEnd = lineStart + lineAt(source, starts, line).length;

    foreach (t; toks)
    {
        if (t.startRow > row)
            break; // position-ordered: nothing later can overlap
        if (t.endRow < row)
            continue;
        const s = t.start > lineStart ? t.start : lineStart;
        const e = t.end < lineEnd ? t.end : lineEnd;
        if (s >= e)
            continue;
        sink ~= RefineToken(s - lineStart, e - s);
    }
}

/// Byte offset of each line's first character.
private size_t[] lineStarts(scope const(char)[] text) @safe pure nothrow
{
    size_t[] starts = [0];
    foreach (i, c; text)
        if (c == '\n' && i + 1 < text.length)
            starts ~= i + 1;
    return starts;
}

/// The 1-based `line` of `text` without its newline, or `null` when out of
/// range.
private const(char)[] lineAt(return scope const(char)[] text,
    scope const(size_t)[] starts, uint line) @safe pure nothrow @nogc
{
    if (line == 0 || line > starts.length)
        return null;
    const start = starts[line - 1];
    auto end = line < starts.length ? starts[line] : text.length;
    if (end > start && text[end - 1] == '\n')
        --end;
    return text[start .. end];
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("diff_token_view.lineAt.boundaries")
@safe pure nothrow unittest
{
    enum text = "one\ntwo\nthree";
    const starts = lineStarts(text);
    assert(starts == [0, 4, 8]);
    assert(lineAt(text, starts, 1) == "one");
    assert(lineAt(text, starts, 2) == "two");
    assert(lineAt(text, starts, 3) == "three");
    assert(lineAt(text, starts, 4) is null);

    // A trailing newline does not open a fourth line.
    enum closed = "one\ntwo\n";
    const cs = lineStarts(closed);
    assert(cs == [0, 4]);
    assert(lineAt(closed, cs, 2) == "two");
}
