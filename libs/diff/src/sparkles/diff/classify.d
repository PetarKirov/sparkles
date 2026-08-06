/**
Hunk classification (`DVN2`) — deciding which changes are noise.

The complement of [normalize](sparkles/diff/normalize.d)'s `DVN1`. Both answer
"is this really a change", and the difference is what the reviewer gets:

$(UL
$(LI `DVN1` is a **policy**: whitespace differences never become changes, so
    the rows are gone from the model entirely.)
$(LI `DVN2` is a **verdict**: the rows stay, carrying a classification the
    renderers use to dim and fold them behind a count badge.)
)

Demote rather than hide is the unanimous finding of the prior-art survey
(WinMerge's `OP_TRIVIAL`, Gerrit's `common:true`, Beyond Compare's
blue-importance): a reviewer must be able to see what was called noise, or the
tool is asking to be trusted about the one thing it could be wrong about. So
the default policy stays `exact` and this pass does the demoting.

The verdict is deliberately conservative — a hunk is formatting-only when
$(I every) changed row is provably so. One real edit anywhere in the hunk makes
the whole hunk real, because a hunk is what a reviewer expands as a unit.
*/
module sparkles.diff.classify;

import sparkles.diff.model : DiffDoc, Hunk, Row, RowKind;
import sparkles.diff.normalize : isBlank, linesEqual, WhitespaceMode;

/**
Classifies every hunk of `doc`, stamping `Hunk.formattingOnly`.

Runs after pairing (`DVM2`), because the verdict for a changed line is "does
its counterpart say the same thing" — and which line is its counterpart is
exactly what pairing decides.
*/
void classifyHunks(ref DiffDoc doc) @safe pure nothrow @nogc
{
    foreach (hi; 0 .. doc.hunks.length)
    {
        auto h = doc.hunks[hi];
        h.formattingOnly = isFormattingOnly(doc, h);
        doc.hunks[hi] = h;
    }
}

/**
`true` when every changed row in `hunk` is formatting: a blank-line insertion
or removal, or a row whose paired counterpart carries the same non-whitespace
content.

A hunk with no changed rows at all is not formatting-only — it is not a change
at all, and calling it noise would put a "1 formatting-only hunk" badge on
something that never appears.
*/
bool isFormattingOnly(const ref DiffDoc doc, in Hunk hunk) @safe pure nothrow @nogc
{
    const rows = doc.hunkRows(hunk);
    bool sawChange;
    foreach (i, ref row; rows)
    {
        if (row.kind == RowKind.context)
            continue;
        sawChange = true;

        const text = doc.rowText(row);
        // A blank line added or removed is formatting on its own terms — it
        // has no content to compare against a counterpart.
        if (isBlank(text))
            continue;

        // Otherwise the row must pair with a counterpart that says the same
        // thing. An UNPAIRED non-blank row is a real insertion or deletion:
        // there is nothing to be equivalent to.
        if (row.pair < 0 || cast(size_t) row.pair >= rows.length)
            return false;
        const other = rows[cast(size_t) row.pair];
        // `all` rather than `change` here: the question is whether the two
        // lines carry the same content, and this pass is the one place where
        // "same content, different spacing" is precisely what we are looking
        // for — including spacing added where there was none.
        if (!linesEqual(text, doc.rowText(other), WhitespaceMode.all))
            return false;
    }
    return sawChange;
}

/// How many of `doc`'s hunks are classified formatting-only — the count a
/// badge shows ("3 formatting-only hunks").
size_t formattingOnlyCount(const ref DiffDoc doc) @safe pure nothrow @nogc
{
    size_t n;
    foreach (i; 0 .. doc.hunks.length)
        if (doc.hunks[i].formattingOnly)
            ++n;
    return n;
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("classify.isFormattingOnly.repaddedRowsAreNoise")
@safe pure nothrow @nogc
unittest
{
    import sparkles.diff.engine : diffText;

    // The motivating scenario at the DEFAULT policy: every row was re-padded
    // and nothing else changed, so the reviewer sees the rows (they are real
    // text edits) but the hunk is marked noise.
    enum oldTable = "| a | b |\n| c | d |\n";
    enum newTable = "| a   | b |\n| c   | d |\n";

    auto doc = diffText(oldTable, newTable);
    classifyHunks(doc);
    assert(doc.hunks.length == 1);
    assert(doc.hunks[0].formattingOnly);
    assert(formattingOnlyCount(doc) == 1);
}

@("classify.isFormattingOnly.oneRealEditMakesTheHunkReal")
@safe pure nothrow @nogc
unittest
{
    import sparkles.diff.engine : diffText;

    // Same re-padding, plus one changed cell. A hunk is what a reviewer
    // expands as a unit, so one real edit anywhere in it makes the whole hunk
    // real — dimming it would hide the edit inside the noise.
    enum oldTable = "| a | b |\n| c | d |\n";
    enum newTable = "| a   | b |\n| c   | D |\n";

    auto doc = diffText(oldTable, newTable);
    classifyHunks(doc);
    assert(!doc.hunks[0].formattingOnly);
    assert(formattingOnlyCount(doc) == 0);
}

@("classify.isFormattingOnly.blankLineChurn")
@safe pure nothrow @nogc
unittest
{
    import sparkles.diff.engine : diffText;

    // A blank line added is formatting on its own terms: there is no
    // counterpart to compare it against, and nothing was said.
    auto doc = diffText("a\nb\n", "a\n\nb\n");
    classifyHunks(doc);
    assert(doc.hunks[0].formattingOnly);

    // But an added line WITH content is a real change, paired or not.
    auto real_ = diffText("a\nb\n", "a\nnew\nb\n");
    classifyHunks(real_);
    assert(!real_.hunks[0].formattingOnly);
}

@("classify.isFormattingOnly.identicalFileHasNothingToClassify")
@safe pure nothrow @nogc
unittest
{
    import sparkles.diff.engine : diffText;

    // No changed rows ⇒ not "formatting-only", which would otherwise put a
    // noise badge on a file nobody touched.
    auto doc = diffText("a\nb\n", "a\nb\n");
    classifyHunks(doc);
    assert(formattingOnlyCount(doc) == 0);
    foreach (i; 0 .. doc.hunks.length)
        assert(!doc.hunks[i].formattingOnly);
}

@("classify.isFormattingOnly.indentationOnly")
@safe pure nothrow @nogc
unittest
{
    import sparkles.diff.engine : diffText;

    // The other everyday case: a block re-indented, tabs to spaces.
    enum before = "void f()\n{\n\tint x;\n\treturn;\n}\n";
    enum after = "void f()\n{\n    int x;\n    return;\n}\n";
    auto doc = diffText(before, after);
    classifyHunks(doc);
    assert(doc.hunks[0].formattingOnly);
}
