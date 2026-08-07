/**
`DST2`/`DST6`: turning a selection into a patch that `git apply` will take.

The lazygit recipe, and for lazygit's reason: there is no in-process index to
keep in sync, so staging a selection means synthesizing a patch containing
exactly the selected changes and handing it to git —
`git apply --cached --unidiff-zero` to stage, the same patch `--reverse` to
unstage, and `--check` first so a patch that would not apply is reported
instead of half-applied.

$(B Zero context is not an optimization.) A hunk carries three context lines
either side; a sub-patch that kept them would fail to apply the moment the
lines around the selection differ from what the index holds — which is exactly
the situation staging one hunk out of several creates. Emitting no context at
all is what `--unidiff-zero` exists for.

$(B `DST6`: what is shown and what is applied are different questions.) The
selection this module takes is over MODEL rows, not visible ones. A hunk
folded as noise, a collapsed file, a hidden unchanged region — none of it
changes the bytes staged, because the reviewer selected a range of the change,
not a range of the screen.
*/
module sparkles.diff.stage;

import std.range.primitives : put;

import sparkles.diff.model : DiffDoc, FileEntry, Hunk, Row, RowKind;

/**
Emits a patch for the selected rows of one file.

`selected` is indexed by the document's global row index, so a caller can hand
over the whole document's selection and let each file take its own. Rows that
are not changes are ignored whatever the selection says — staging a context
line is not a thing, and silently including one would corrupt the patch.

Writes nothing at all when the selection contains no changed row of this file,
so a caller can emit several files into one buffer and get a patch with only
the files that had something in them.

Returns the number of hunks emitted.
*/
uint emitSelectionPatch(Writer)(in DiffDoc doc, in FileEntry file,
    scope const(bool)[] selected, ref Writer w) @safe
{
    // A first pass decides whether there is anything to write, because the
    // file header must not be emitted for a file with no selected rows.
    if (!anySelected(doc, file, selected))
        return 0;

    const oldPath = doc.pathText(file.oldPath);
    const newPath = doc.pathText(file.newPath);
    put(w, "diff --git a/");
    put(w, oldPath);
    put(w, " b/");
    put(w, newPath);
    put(w, "\n--- ");
    if (oldPath != "/dev/null")
        put(w, "a/");
    put(w, oldPath);
    put(w, "\n+++ ");
    if (newPath != "/dev/null")
        put(w, "b/");
    put(w, newPath);
    put(w, "\n");

    uint hunks;
    // `delta` tracks how far the new side has drifted from the old one across
    // everything already included. Unselected changes contribute nothing:
    // they are not being applied, so they move neither side.
    long delta;

    foreach (hi; file.hunksStart .. file.hunksStart + file.hunksCount)
    {
        const hunk = doc.hunks[hi];
        const start = hunk.rowsStart;
        const end = hunk.rowsStart + hunk.rowsCount;

        size_t i = start;
        while (i < end)
        {
            if (!isSelectedChange(doc, i, selected))
            {
                ++i;
                continue;
            }
            // A run of consecutive selected changes becomes one hunk.
            size_t runEnd = i;
            uint removed, added;
            while (runEnd < end && isSelectedChange(doc, runEnd, selected))
            {
                if (doc.rows[runEnd].kind == RowKind.removed)
                    ++removed;
                else
                    ++added;
                ++runEnd;
            }

            const oldStart = runOldStart(doc, i, start);
            // Where this run lands on the new side. git spells the three
            // shapes differently, and `--unidiff-zero` still LOCATES by these
            // numbers, so getting them wrong is a failed apply, not a
            // cosmetic slip:
            //   replacement  `@@ -5,1 +5,1 @@`  — same line
            //   insertion    `@@ -5,0 +6,1 @@`  — after old line 5
            //   deletion     `@@ -5,1 +4,0 @@`  — after new line 4
            auto newStart = cast(long) oldStart + delta;
            if (removed == 0)
                ++newStart;
            else if (added == 0)
                --newStart;
            emitHeader(w, oldStart, removed,
                newStart < 0 ? 0 : cast(ulong) newStart, added);
            foreach (ri; i .. runEnd)
            {
                const row = doc.rows[ri];
                put(w, row.kind == RowKind.removed ? "-" : "+");
                put(w, doc.rowText(row));
                put(w, "\n");
            }
            delta += cast(long) added - cast(long) removed;
            ++hunks;
            i = runEnd;
        }
    }
    return hunks;
}

/// The old-side line a run starts at.
///
/// A run of removals starts at the first removed line. A run that begins with
/// an ADDITION has no old line of its own — it is an insertion, and git wants
/// the line it comes after, so the count-zero form `@@ -N,0 +M,k @@` is read
/// as "insert after N".
private ulong runOldStart(in DiffDoc doc, size_t runStart, size_t hunkStart)
    @safe pure nothrow @nogc
{
    const row = doc.rows[runStart];
    if (row.oldLine != 0)
        return row.oldLine;
    // Walk back for the nearest row that has an old line; an addition at the
    // very start of a file has none, which is line 0 — "insert at the top".
    size_t i = runStart;
    while (i > hunkStart)
    {
        --i;
        if (doc.rows[i].oldLine != 0)
            return doc.rows[i].oldLine;
    }
    return 0;
}

private void emitHeader(Writer)(ref Writer w, ulong oldStart, uint oldCount,
    ulong newStart, uint newCount) @safe
{
    import sparkles.base.text.writers : writeInteger;

    put(w, "@@ -");
    writeInteger(w, oldStart);
    put(w, ",");
    writeInteger(w, oldCount);
    put(w, " +");
    writeInteger(w, newStart);
    put(w, ",");
    writeInteger(w, newCount);
    put(w, " @@\n");
}

private bool isSelectedChange(in DiffDoc doc, size_t rowIndex,
    scope const(bool)[] selected) @safe pure nothrow @nogc
    => rowIndex < selected.length && selected[rowIndex]
    && doc.rows[rowIndex].kind != RowKind.context;

private bool anySelected(in DiffDoc doc, in FileEntry file,
    scope const(bool)[] selected) @safe pure nothrow @nogc
{
    foreach (hi; file.hunksStart .. file.hunksStart + file.hunksCount)
    {
        const hunk = doc.hunks[hi];
        foreach (ri; hunk.rowsStart .. hunk.rowsStart + hunk.rowsCount)
            if (isSelectedChange(doc, ri, selected))
                return true;
    }
    return false;
}

/// Marks every changed row of the hunk with `hunkId` — the default selection
/// unit (`DST3`: hunk mode), expressed over ids so it survives a recompute.
void selectHunk(in DiffDoc doc, ulong hunkId, scope bool[] selected)
    @safe pure nothrow @nogc
{
    foreach (hi; 0 .. doc.hunks.length)
    {
        const hunk = doc.hunks[hi];
        if (hunk.id != hunkId)
            continue;
        foreach (ri; hunk.rowsStart .. hunk.rowsStart + hunk.rowsCount)
            if (ri < selected.length && doc.rows[ri].kind != RowKind.context)
                selected[ri] = true;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("stage.emitSelectionPatch.oneHunkOfSeveral")
@safe unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.diff.engine : diffText;
    import sparkles.diff.patch : parsePatch;

    // Two changes far apart; the reviewer stages only the second.
    enum before = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n";
    enum after = "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n";
    auto doc = diffText(before, after, "f.txt", "f.txt");
    assert(doc.hunks.length == 2, "precondition: two hunks");

    auto selected = new bool[](doc.rows.length);
    selectHunk(doc, doc.hunks[1].id, selected);

    SmallBuffer!char buf;
    const n = emitSelectionPatch(doc, doc.files[0], selected, buf);
    assert(n == 1, "one run of selected changes");

    // It must be a patch git would take — and the parser is the same grammar.
    auto parsed = parsePatch(buf[]);
    assert(!parsed.hasError, "the synthesized patch must parse");
    assert(parsed.value.files.length == 1);

    // Zero context: nothing but the selected change is in it.
    size_t context;
    foreach (i; 0 .. parsed.value.rows.length)
        if (parsed.value.rows[i].kind == RowKind.context)
            ++context;
    assert(context == 0, "context lines would fail to apply against the index");

    // And it carries the SECOND change, not the first.
    import std.algorithm.searching : canFind;

    assert(buf[].canFind("+L"), "the staged change");
    assert(!buf[].canFind("+B"), "the change the reviewer did not stage");
}

@("stage.emitSelectionPatch.perLineWithinAHunk")
@safe unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.diff.engine : diffText;
    import sparkles.diff.patch : parsePatch;
    import std.algorithm.searching : canFind;

    // Three consecutive edits in one hunk; only the middle one is staged.
    // This is the case a hunk-granular tool cannot express at all.
    auto doc = diffText("one\ntwo\nthree\n", "ONE\nTWO\nTHREE\n", "f", "f");
    auto selected = new bool[](doc.rows.length);
    foreach (i; 0 .. doc.rows.length)
    {
        const row = doc.rows[i];
        if ((row.kind == RowKind.removed && doc.rowText(row) == "two")
            || (row.kind == RowKind.added && doc.rowText(row) == "TWO"))
            selected[i] = true;
    }

    SmallBuffer!char buf;
    assert(emitSelectionPatch(doc, doc.files[0], selected, buf) >= 1);
    auto parsed = parsePatch(buf[]);
    assert(!parsed.hasError);

    assert(buf[].canFind("-two") && buf[].canFind("+TWO"));
    assert(!buf[].canFind("-one") && !buf[].canFind("+ONE"));
    assert(!buf[].canFind("three"), "neither side of the unstaged edit");
}

@("stage.emitSelectionPatch.nothingSelectedWritesNothing")
@safe unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.diff.engine : diffText;

    auto doc = diffText("a\n", "b\n", "f", "f");
    auto none = new bool[](doc.rows.length);

    SmallBuffer!char buf;
    assert(emitSelectionPatch(doc, doc.files[0], none, buf) == 0);
    assert(buf[].length == 0,
        "a file with nothing selected contributes no header either");

    // A selection naming only context rows is the same as none: staging a
    // context line is not a thing, and including one would corrupt the patch.
    auto contextOnly = new bool[](doc.rows.length);
    contextOnly[] = true;
    SmallBuffer!char buf2;
    auto ctxDoc = diffText("keep\nkeep\n", "keep\nkeep\n", "f", "f");
    auto all = new bool[](ctxDoc.rows.length);
    all[] = true;
    assert(emitSelectionPatch(ctxDoc, ctxDoc.files[0], all, buf2) == 0);
}

@("stage.selectHunk.namesTheHunkByIdNotByIndex")
@safe unittest
{
    import sparkles.diff.engine : diffText;

    enum before = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n";
    enum after = "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n";
    auto doc = diffText(before, after, "f", "f");

    auto selected = new bool[](doc.rows.length);
    selectHunk(doc, doc.hunks[0].id, selected);

    // Only the first hunk's changed rows, and none of its context — the
    // selection unit is the change, not the display.
    foreach (i; 0 .. doc.rows.length)
    {
        const inFirstHunk = i >= doc.hunks[0].rowsStart
            && i < doc.hunks[0].rowsStart + doc.hunks[0].rowsCount;
        const changed = doc.rows[i].kind != RowKind.context;
        assert(selected[i] == (inFirstHunk && changed));
    }
}
