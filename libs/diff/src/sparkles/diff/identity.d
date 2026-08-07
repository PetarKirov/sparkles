/**
`DST1`: content-derived identities for hunks and rows.

Interactive state outlives the model it points at. A reviewer stages a hunk,
edits the file, and the diff is recomputed from scratch — new arena, new
indices, and every index the UI was holding now names something else. The
gitui answer, adopted here: the UI remembers a HASH, the backend re-derives
the diff, and the two are re-matched by content.

So an id is derived from what a row or hunk SAYS, never from where it sits.
Line numbers shift when anything above changes; text does not. That is the
whole design constraint, and the reason $(LREF stampIds) hashes row text and
kind rather than the unified header's coordinates.

Two identical hunks in one file would then share an id, which for staging is
not a curiosity but a bug — "stage this one" must not stage the other. Each id
therefore mixes in how many identical predecessors it has within its file, so
duplicates stay distinguishable while both stay stable under line shifts.
*/
module sparkles.diff.identity;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.diff.model : DiffDoc, Hunk, Row, RowKind;

@safe pure nothrow @nogc:

/// FNV-1a, 64-bit. Not a security hash and not required to be: this is a
/// re-matching key for a UI, where a collision costs a mis-restored
/// selection, and the alternative — an index — is wrong every single time
/// the document changes above it.
enum ulong fnvOffset = 0xcbf2_9ce4_8422_2325;
/// ditto
enum ulong fnvPrime = 0x0000_0100_0000_01b3;

/// ditto
ulong hashBytes(scope const(char)[] bytes, ulong seed = fnvOffset)
{
    auto h = seed;
    foreach (b; bytes)
    {
        h ^= cast(ubyte) b;
        h *= fnvPrime;
    }
    return h;
}

/// ditto
ulong hashByte(ubyte b, ulong seed = fnvOffset)
{
    auto h = seed;
    h ^= b;
    h *= fnvPrime;
    return h;
}

/// One row's identity: its kind and its text. A context row that becomes a
/// removed row is a different row, which is the right answer — the reviewer's
/// selection of it should not survive that.
ulong rowId(in DiffDoc doc, in Row row)
    => hashBytes(doc.rowText(row), hashByte(cast(ubyte) row.kind));

/**
Stamps every hunk and row of `doc` with its content id.

Called at the end of both document sources (the engine and the patch parser),
so no consumer can be handed a document whose ids are absent — an id that is
sometimes zero is worse than none, because the code that reads it looks
correct.
*/
void stampIds(ref DiffDoc doc)
{
    // Occurrence counters, so identical content in one file still yields
    // distinct ids. Small buffers rather than a map: a file's duplicate
    // hunks are few, and the engine is `@nogc`.
    SmallBuffer!ulong seenHunks;
    SmallBuffer!ulong seenRows;

    static uint bump(ref SmallBuffer!ulong seen, ulong id)
    {
        uint n;
        foreach (i; 0 .. seen.length)
            if (seen[i] == id)
                ++n;
        seen ~= id;
        return n;
    }

    foreach (fi; 0 .. doc.files.length)
    {
        const file = doc.files[fi];
        seenHunks.length = 0;
        foreach (hi; file.hunksStart .. file.hunksStart + file.hunksCount)
        {
            auto hunk = doc.hunks[hi];
            seenRows.length = 0;

            // The hunk's id is its CHANGED rows, in order — not its header,
            // and not its context. Context is incidental: inserting a line
            // three above a hunk rewrites its leading context row and every
            // coordinate in its header without touching the change itself,
            // and a reviewer who staged that change still means that change.
            ulong acc = fnvOffset;
            foreach (ri; hunk.rowsStart .. hunk.rowsStart + hunk.rowsCount)
            {
                auto row = doc.rows[ri];
                const id = rowId(doc, row);
                row.id = mix(id, bump(seenRows, id));
                doc.rows[ri] = row;
                if (row.kind == RowKind.context)
                    continue;
                acc = hashByte(cast(ubyte) row.kind, acc);
                acc = hashBytes(doc.rowText(row), acc);
            }
            hunk.id = mix(acc, bump(seenHunks, acc));
            doc.hunks[hi] = hunk;
        }
    }
}

/// Folds an occurrence ordinal into an id. Zero occurrences leaves the hash
/// untouched, so the common case (nothing duplicated) reads as a plain
/// content hash.
private ulong mix(ulong id, uint occurrence)
{
    if (occurrence == 0)
        return id;
    auto h = id;
    foreach (_; 0 .. 8)
    {
        h = hashByte(cast(ubyte) occurrence, h);
        occurrence >>= 8;
    }
    return h;
}

@("identity.stampIds.survivesLineShiftsButNotEdits")
@safe pure nothrow @nogc
unittest
{
    import sparkles.diff.engine : diffText;

    // The same change, once at the top of a file and once pushed down by
    // lines added above it. Every coordinate differs; the identity must not.
    auto a = diffText("one\ntwo\n", "one\nTWO\n", "f", "f");
    auto b = diffText("pad\npad\npad\none\ntwo\n",
        "pad\npad\npad\none\nTWO\n", "f", "f");
    stampIds(a);
    stampIds(b);

    assert(a.hunks[0].oldStart != b.hunks[0].oldStart, "precondition: shifted");
    assert(a.hunks[0].id == b.hunks[0].id,
        "an id derived from position would have changed here");

    // An actual edit is a different hunk.
    auto c = diffText("one\ntwo\n", "one\nTHREE\n", "f", "f");
    stampIds(c);
    assert(c.hunks[0].id != a.hunks[0].id);
}

@("identity.stampIds.duplicatesStayDistinct")
@safe pure nothrow @nogc
unittest
{
    import sparkles.diff.engine : diffText;

    // Two identical changes in one file, far enough apart to be two hunks.
    // "Stage this one" must not stage the other, so their ids must differ —
    // while each stays stable under shifts.
    enum before = "x\na\nb\nc\nd\ne\nf\ng\nh\ni\nj\nx\n";
    enum after = "y\na\nb\nc\nd\ne\nf\ng\nh\ni\nj\ny\n";
    auto doc = diffText(before, after, "f", "f");
    stampIds(doc);

    assert(doc.hunks.length == 2, "precondition: two separate hunks");
    assert(doc.hunks[0].id != doc.hunks[1].id,
        "identical content in one file must still be two identities");

    // And the rows within them likewise.
    assert(doc.rows[doc.hunks[0].rowsStart].id
        != doc.rows[doc.hunks[1].rowsStart].id);
}

@("identity.rowId.kindIsPartOfIt")
@safe pure nothrow @nogc
unittest
{
    DiffDoc doc;
    doc.oldText = "same\n";
    doc.newText = "same\n";
    const removed = Row(RowKind.removed, 1, 0, doc.rows.length == 0
        ? typeof(Row.src)(0, 4) : typeof(Row.src)(0, 4));
    const added = Row(RowKind.added, 0, 1, typeof(Row.src)(0, 4));

    // Same text, different side: a context line that becomes a removed line
    // is not the same row, and a selection of it should not survive that.
    assert(rowId(doc, removed) != rowId(doc, added));
}
