/// The composed engine entry point: two texts in, one `DiffDoc` out —
/// line diff (`DVM1`), per-hunk similarity pairing (`DVM2`) and word
/// refinement (`DVM4`), with the scale guards of `DVM6`. `@nogc` end to end
/// (`DVM8`). The flagship golden test is the spec's motivating scenario
/// (`DVN4` substrate): a re-padded markdown table where only the truly
/// changed cell may light up on the changed row.
module sparkles.diff.engine;

import sparkles.diff.model : Degradation, DiffDoc, DiffOptions, FileEntry, Row,
    RowKind, Span;
import sparkles.diff.myers : buildHunks, buildRows, diffLines, splitDiffLines;
import sparkles.diff.pairing : pairChangeBlocks;
import sparkles.diff.refine : refineRows;

/// Diff two in-memory texts into a one-file document. The result **borrows**
/// both inputs (row `src` spans reference them) — keep them alive as long as
/// the document. The paths are copied into the document's owned arena.
DiffDoc diffText(const(char)[] oldText, const(char)[] newText,
    scope const(char)[] oldPath = "a", scope const(char)[] newPath = "b",
    in DiffOptions opt = DiffOptions()) @safe pure nothrow @nogc
{
    DiffDoc doc;
    doc.oldText = oldText;
    doc.newText = newText;

    FileEntry file;
    file.oldPath = doc.internPath(oldPath);
    file.newPath = doc.internPath(newPath);

    if (oldText.length > opt.maxFileBytes || newText.length > opt.maxFileBytes)
    {
        file.degraded = Degradation.fileTooLarge;
        doc.files ~= file;
        return doc;
    }

    auto oldLines = splitDiffLines(oldText, file.oldMissingNewline);
    auto newLines = splitDiffLines(newText, file.newMissingNewline);

    auto d = diffLines(oldText, oldLines, newText, newLines, opt.maxEditDistance);
    file.degraded = d.degraded;

    doc.rows = buildRows(oldLines, newLines, d);
    doc.hunks = buildHunks(doc.rows, opt.context);
    file.hunksStart = 0;
    file.hunksCount = cast(uint) doc.hunks.length;

    foreach (hi; 0 .. doc.hunks.length)
    {
        const h = doc.hunks[hi];
        scope rows = doc.rows[][h.rowsStart .. h.rowsStart + h.rowsCount];
        if (opt.pairRows)
            pairChangeBlocks(rows, oldText, newText, opt);
        if (opt.refineWords)
            refineRows(rows, oldText, newText, doc.emph, opt);
    }

    doc.files ~= file;
    return doc;
}

@("engine.diffText.identical-inputs-empty-diff")
@safe pure nothrow @nogc
unittest
{
    auto doc = diffText("a\nb\n", "a\nb\n");
    assert(doc.files.length == 1);
    assert(doc.files[0].hunksCount == 0);
    assert(doc.files[0].degraded == Degradation.none);
}

@("engine.diffText.simple-change")
@safe pure nothrow @nogc
unittest
{
    auto doc = diffText("one\ntwo\nthree\n", "one\n2\nthree\n");
    const f = doc.files[0];
    assert(f.hunksCount == 1);
    const h = doc.fileHunks(f)[0];
    const rows = doc.hunkRows(h);
    assert(rows.length == 4);
    assert(rows[0].kind == RowKind.context);
    assert(rows[1].kind == RowKind.removed && doc.rowText(rows[1]) == "two");
    assert(rows[2].kind == RowKind.added && doc.rowText(rows[2]) == "2");
    assert(h.oldStart == 1 && h.oldCount == 3);
    assert(doc.pathText(f.oldPath) == "a");
}

@("engine.diffText.file-too-large-guard")
@safe pure nothrow @nogc
unittest
{
    DiffOptions opt;
    opt.maxFileBytes = 4;
    auto doc = diffText("aaaaaaaa", "b", "a", "b", opt);
    assert(doc.files[0].degraded == Degradation.fileTooLarge);
    assert(doc.files[0].hunksCount == 0);
}

@("engine.diffText.missing-newline-flags")
@safe pure nothrow @nogc
unittest
{
    auto doc = diffText("a\nb", "a\nc\n");
    assert(doc.files[0].oldMissingNewline);
    assert(!doc.files[0].newMissingNewline);
}

@("engine.golden.markdown-table-repad")
@safe pure nothrow @nogc
unittest
{
    // The motivating scenario (diff-view.md DVN4 substrate): a formatter
    // widened every row of the table while exactly one cell changed.
    enum oldTable = "| Name | Role |\n"
        ~ "| ---- | ---- |\n"
        ~ "| ann | dev |\n"
        ~ "| bob | ops |\n"
        ~ "| cal | qa |\n";
    enum newTable = "| Name    | Role |\n"
        ~ "| ------- | ---- |\n"
        ~ "| ann     | dev |\n"
        ~ "| bob     | sre |\n"
        ~ "| cal     | qa |\n";

    auto doc = diffText(oldTable, newTable);
    const f = doc.files[0];
    assert(f.hunksCount == 1);
    const rows = doc.hunkRows(doc.fileHunks(f)[0]);

    // 1. Every removed row pairs with its re-padded counterpart — the
    //    realignment never desynchronizes the row mapping.
    size_t pairs = 0;
    foreach (ref row; rows)
    {
        if (row.kind != RowKind.removed)
            continue;
        assert(row.pair >= 0, "re-padded row failed to pair");
        const counterpart = rows[cast(size_t) row.pair];
        // The paired row is the same table row: same first cell text —
        // except the separator row, whose dashes legitimately widened.
        if (firstCell(doc.rowText(row))[0] != '-')
            assert(firstCell(doc.rowText(row)) == firstCell(doc.rowText(counterpart)));
        pairs++;
    }
    assert(pairs == 5);

    // 2. On the row with the real change, the emphasis includes the changed
    //    cell on both sides…
    Row bobOld, bobNew;
    bool found = false;
    foreach (ref row; rows)
        if (row.kind == RowKind.removed && firstCell(doc.rowText(row)) == "bob")
        {
            bobOld = row;
            bobNew = rows[cast(size_t) row.pair];
            found = true;
        }
    assert(found);
    assert(spansCover(doc, bobOld, "ops"));
    assert(spansCover(doc, bobNew, "sre"));

    // 3. …and never the unchanged cell.
    assert(!spansCover(doc, bobOld, "bob"));
    assert(!spansCover(doc, bobNew, "bob"));

    // 4. On rows with no content change, no *word* token is emphasized on
    //    the old side — only the padding on the widened side may light up
    //    (its classification as formatting-only noise is the DVN2/DVN4
    //    layer, not V0's job).
    foreach (ref row; rows)
    {
        if (row.kind != RowKind.removed || firstCell(doc.rowText(row)) == "bob")
            continue;
        foreach (s; doc.rowEmph(row))
            foreach (c; doc.rowText(row)[s.start .. s.end])
                assert(c == ' ' || c == '|' || c == '-',
                    "unchanged row emphasized a content byte");
    }
}

version (unittest)
{
    private const(char)[] firstCell(return scope const(char)[] rowText)
        @safe pure nothrow @nogc
    {
        // "| cell | …" → "cell"
        size_t i = 0;
        while (i < rowText.length && (rowText[i] == '|' || rowText[i] == ' '))
            i++;
        immutable start = i;
        while (i < rowText.length && rowText[i] != ' ' && rowText[i] != '|')
            i++;
        return rowText[start .. i];
    }

    private bool spansCover(in DiffDoc doc, in Row row, scope const(char)[] needle)
        @safe pure nothrow @nogc
    {
        const text = doc.rowText(row);
        foreach (s; doc.rowEmph(row))
        {
            auto seg = text[s.start .. s.start + s.length];
            // needle fully inside one emphasized segment?
            if (seg.length >= needle.length)
                foreach (off; 0 .. seg.length - needle.length + 1)
                    if (seg[off .. off + needle.length] == needle)
                        return true;
        }
        return false;
    }
}
