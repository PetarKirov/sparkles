// `DVN6`: diffing markdown as a DOCUMENT rather than as text.
//
// Every other layer in this spec diffs lines. That is the right unit for
// source code and the wrong one for prose: rewrapping a paragraph changes
// every line of it without changing a word, and the motivating scenario —
// a formatter re-aligning a large table — changes every row without changing
// a cell. Both read as a wall of churn in any line-based view, including our
// own after `DVN1`–`DVN4` have done what they can.
//
// So this pass diffs the two `MdDoc` models: blocks aligned against blocks,
// and within a matched pair, words against words. The result is ONE tree the
// existing markdown renderer can draw — the new document's blocks, with the
// removed ones spliced back in at their old positions and a decoration per
// block saying what happened to it. The reviewer reads the rendered document,
// not a diff of its source.
//
// Both sides' spans index their own source, so the merged tree carries a
// merged source (`new ~ old`) and the old side's spans are rebased onto it.
// A block's identity in the decoration channel is its span start, the same
// source-anchored convention the renderer already uses for folds, code tabs
// and table cells.
module md_diff;

import sparkles.syntax.md.model : MdBlock, MdBlockKind, MdDecoration,
    MdDiffStatus, MdDoc, MdInline, Span;

import diff_commutative : normalizedText;

/// The merged document plus its decorations, sorted by `spanStart`.
struct MdDiffResult
{
    MdDoc doc;
    MdDecoration[] decorations;

    /// The verdict for a block, or `unchanged` when it carries none.
    const(MdDecoration) lookup(size_t spanStart) const @safe pure nothrow @nogc
    {
        // Binary search: decorations are emitted in span order.
        size_t lo, hi = decorations.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (decorations[mid].spanStart < spanStart)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo < decorations.length && decorations[lo].spanStart == spanStart)
            return decorations[lo];
        return MdDecoration(spanStart, MdDiffStatus.unchanged);
    }
}

/// Beyond this many blocks at one level the quadratic alignment is skipped
/// and the level pairs positionally (`DVM6`'s family of scale guards): the
/// answer degrades to a coarser one, never to a hang.
enum size_t maxAlignBlocks = 512;

/// Below this similarity two blocks of the same kind are not considered
/// versions of each other — they are an unrelated removal and an unrelated
/// addition. Matches the engine's `minPairSimilarity`, and for the same
/// reason: pairing anything with anything produces word-level confetti
/// between unrelated prose.
///
enum double minBlockSimilarity = 0.4;

/**
Diffs two parsed markdown documents into one renderable tree.

The merged document's source is `newDoc.source ~ oldDoc.source`, with every
span of the old side rebased onto the tail — so one `MdDoc` can hold blocks
from both sides and the renderer needs no second source parameter.

Alignment recurses: two blocks that matched but differ are aligned again
through their children (a table's rows, a list's items, a quote's blocks), so
a one-cell edit in a re-aligned table decorates that cell and nothing else.
*/
MdDiffResult diffMarkdown(const MdDoc oldDoc, const MdDoc newDoc) @safe
{
    MdDiffResult result;
    const offset = newDoc.source.length;
    result.doc.source = newDoc.source.idup ~ oldDoc.source.idup;

    MdDecoration[] decos;
    result.doc.root = MdBlock(kind: MdBlockKind.document);
    result.doc.root.children = mergeLevel(oldDoc.root.children,
        newDoc.root.children, oldDoc.source, newDoc.source, offset, decos);
    result.doc.root.span = Span(0, result.doc.source.length);

    import std.algorithm.sorting : sort;

    result.decorations = decos.sort!((a, b) => a.spanStart < b.spanStart)
        .release;
    return result;
}

/**
Merges one level of two block sequences into the tree to render.

Output order is the unified-diff order a reviewer expects: a removed block
appears where it used to be, immediately before whatever replaced it. A
matched pair contributes the NEW block — that is the document as it now
stands, which is what a rendered preview is for — carrying a decoration when
the two versions differ.

`decos` accumulates across the whole recursion, so one flat channel describes
a tree of any depth.
*/
private MdBlock[] mergeLevel(in MdBlock[] oldBlocks, in MdBlock[] newBlocks,
    scope const(char)[] oldSrc, scope const(char)[] newSrc, size_t offset,
    ref MdDecoration[] decos) @safe
{
    MdBlock[] merged;
    foreach (p; alignBlocks(oldBlocks, newBlocks, oldSrc, newSrc))
    {
        if (p.newIndex == absent)
        {
            // Removed: the old block, rebased onto the merged source's tail.
            auto blk = rebased(oldBlocks[p.oldIndex], offset);
            decos ~= MdDecoration(blk.span.start, MdDiffStatus.removed);
            merged ~= blk;
            continue;
        }
        auto blk = copyBlock(newBlocks[p.newIndex]);
        if (p.oldIndex == absent)
        {
            decos ~= MdDecoration(blk.span.start, MdDiffStatus.added);
            merged ~= blk;
            continue;
        }

        const before = oldBlocks[p.oldIndex];
        if (blockKey(before, oldSrc) == blockKey(blk, newSrc))
        {
            merged ~= blk; // identical: no decoration at all
            continue;
        }

        // Changed. Recurse where the block has structure, so the decoration
        // lands on the cell or list item that actually differs rather than on
        // the whole table.
        const container = blk.children.length != 0 && before.children.length != 0;
        if (container)
            blk.children = mergeLevel(before.children, blk.children, oldSrc,
                newSrc, offset, decos);

        // A container NEVER carries its own verdict — its children do, and
        // they are the precise answer. This is the motivating scenario's crux:
        // re-aligning a table rewrites the raw text of every row, so each row
        // matches its old self only by similarity and would otherwise be
        // stamped `changed` along with the table around it. Decorating all
        // three would tint the whole table to point at one cell, which is the
        // wall of noise this layer exists to remove.
        if (container)
        {
            merged ~= blk;
            continue;
        }
        decos ~= MdDecoration(blk.span.start, MdDiffStatus.changed,
            wordEmphasis(before, oldSrc, blk, newSrc));
        merged ~= blk;
    }
    return merged;
}

/**
Where two versions of one block differ, as byte ranges into the new side.

Reuses the diff engine's guarded refinement — the same LCS, the same token
cap and the same changed-ratio gate that decide intra-line emphasis
everywhere else, so a mostly-rewritten paragraph reads as rewritten instead
of as confetti. Returning empty means "changed, but not localized", which the
renderer draws as a whole-block change.
*/
private Span[] wordEmphasis(in MdBlock before, scope const(char)[] oldSrc,
    in MdBlock after, scope const(char)[] newSrc) @safe
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.diff : DiffOptions, refinePairTokens, refineTokenize, Row,
        RowKind, Span_ = Span;

    // A block with children is decorated through them; emphasizing its whole
    // extent as well would double-mark everything inside it.
    if (after.children.length != 0)
        return null;
    if (before.span.end > oldSrc.length || after.span.end > newSrc.length)
        return null;
    const a = oldSrc[before.span.start .. before.span.end];
    const b = newSrc[after.span.start .. after.span.end];
    if (a.length == 0 || b.length == 0)
        return null;

    Row oldRow = Row(RowKind.removed);
    Row newRow = Row(RowKind.added);
    SmallBuffer!Span_ arena;
    refinePairTokens(oldRow, a, refineTokenize(a), newRow, b,
        refineTokenize(b), arena, DiffOptions.init);

    Span[] spans;
    foreach (i; newRow.emphStart .. newRow.emphStart + newRow.emphCount)
    {
        const s = arena[i];
        spans ~= Span(after.span.start + s.start, after.span.start + s.end);
    }
    return spans;
}

/// A block deep-copied with every span shifted by `offset` — how the old
/// side's blocks come to index the merged source.
private MdBlock rebased(const ref MdBlock blk, size_t offset) @safe
{
    auto out_ = copyBlock(blk);
    shiftSpans(out_, offset);
    return out_;
}

private void shiftSpans(ref MdBlock blk, size_t offset) @safe
{
    blk.span = Span(blk.span.start + offset, blk.span.end + offset);
    if (blk.kind == MdBlockKind.codeFence)
        blk.codeBody = Span(blk.codeBody.start + offset,
            blk.codeBody.end + offset);
    foreach (ref inl; blk.inlines)
        shiftInline(inl, offset);
    foreach (ref child; blk.children)
        shiftSpans(child, offset);
}

private void shiftInline(ref MdInline inl, size_t offset) @safe
{
    inl.span = Span(inl.span.start + offset, inl.span.end + offset);
    foreach (ref child; inl.children)
        shiftInline(child, offset);
}

/// A mutable deep copy. The model's array fields are mutable, so a `const`
/// block cannot simply be assigned into the tree being built — and the merged
/// tree genuinely owns its children (a changed block's are rebuilt).
private MdBlock copyBlock(const ref MdBlock blk) @safe
{
    MdBlock out_;
    out_.kind = blk.kind;
    out_.level = blk.level;
    out_.ordered = blk.ordered;
    out_.checkbox = blk.checkbox;
    out_.infoLang = blk.infoLang;
    out_.label = blk.label;
    out_.codeBody = blk.codeBody;
    out_.span = blk.span;
    out_.aligns = blk.aligns.dup;
    out_.inlines = copyInlines(blk.inlines);
    foreach (ref child; blk.children)
        out_.children ~= copyBlock(child);
    return out_;
}

private MdInline[] copyInlines(const(MdInline)[] inls) @safe
{
    MdInline[] out_;
    foreach (ref inl; inls)
    {
        MdInline copy;
        copy.kind = inl.kind;
        copy.span = inl.span;
        copy.linkDest = inl.linkDest;
        copy.children = copyInlines(inl.children);
        out_ ~= copy;
    }
    return out_;
}

/// One entry of an alignment: an index into each side, or `absent`.
private enum size_t absent = size_t.max;

private struct Pairing
{
    size_t oldIndex = absent;
    size_t newIndex = absent;
}

/**
Aligns two block sequences, returning the merge in output order.

An LCS over block keys (kind + whitespace-normalized text) finds what did not
change; the unmatched runs between matches are then paired off by similarity,
so an edited paragraph becomes one `changed` entry rather than a removal
followed by an unrelated addition. Leftovers on either side stay pure
removals and additions.
*/
private Pairing[] alignBlocks(in MdBlock[] a, in MdBlock[] b,
    scope const(char)[] aSrc, scope const(char)[] bSrc) @safe
{
    auto keysA = new string[](a.length);
    auto keysB = new string[](b.length);
    foreach (i, ref blk; a)
        keysA[i] = blockKey(blk, aSrc);
    foreach (i, ref blk; b)
        keysB[i] = blockKey(blk, bSrc);

    auto matched = a.length * b.length <= maxAlignBlocks * maxAlignBlocks
        ? lcsPairs(keysA, keysB) : positionalPairs(keysA, keysB);

    // Walk both sides, emitting the unmatched runs between matches.
    Pairing[] out_;
    size_t i, j, m;
    while (i < a.length || j < b.length)
    {
        const nextA = m < matched.length ? matched[m].oldIndex : a.length;
        const nextB = m < matched.length ? matched[m].newIndex : b.length;
        out_ ~= pairRun(a[i .. nextA], i, b[j .. nextB], j, aSrc, bSrc, keysA,
            keysB);
        i = nextA;
        j = nextB;
        if (m < matched.length)
        {
            out_ ~= matched[m];
            ++i;
            ++j;
            ++m;
        }
    }
    return out_;
}

/// One run of unmatched blocks on each side: same-kind blocks similar enough
/// to be versions of each other pair up; the rest are removals and additions.
private Pairing[] pairRun(in MdBlock[] a, size_t aBase, in MdBlock[] b,
    size_t bBase, scope const(char)[] aSrc, scope const(char)[] bSrc,
    in string[] keysA, in string[] keysB) @safe
{
    Pairing[] out_;
    auto usedB = new bool[](b.length);
    foreach (x; 0 .. a.length)
    {
        size_t best = absent;
        double bestScore = minBlockSimilarity;
        foreach (y; 0 .. b.length)
        {
            if (usedB[y] || a[x].kind != b[y].kind)
                continue;
            const s = similarity(keysA[aBase + x], keysB[bBase + y]);
            if (s > bestScore)
            {
                bestScore = s;
                best = y;
            }
        }
        if (best == absent)
        {
            out_ ~= Pairing(aBase + x, absent);
            continue;
        }
        usedB[best] = true;
        // Anything on the new side before the match is an insertion.
        foreach (y; 0 .. best)
            if (!usedB[y])
            {
                usedB[y] = true;
                out_ ~= Pairing(absent, bBase + y);
            }
        out_ ~= Pairing(aBase + x, bBase + best);
    }
    foreach (y; 0 .. b.length)
        if (!usedB[y])
            out_ ~= Pairing(absent, bBase + y);
    return out_;
}

/// Classic LCS over the keys, returning the matched index pairs in order.
private Pairing[] lcsPairs(in string[] a, in string[] b) @safe
{
    const n = a.length, m = b.length;
    if (n == 0 || m == 0)
        return null;
    const w = m + 1;
    auto table = new uint[]((n + 1) * w);
    foreach (i; 0 .. n)
        foreach (j; 0 .. m)
            table[(i + 1) * w + j + 1] = a[i] == b[j]
                ? table[i * w + j] + 1
                : (table[i * w + j + 1] > table[(i + 1) * w + j]
                    ? table[i * w + j + 1] : table[(i + 1) * w + j]);

    Pairing[] pairs;
    size_t i = n, j = m;
    while (i > 0 && j > 0)
    {
        if (a[i - 1] == b[j - 1]
            && table[i * w + j] == table[(i - 1) * w + j - 1] + 1)
        {
            pairs ~= Pairing(i - 1, j - 1);
            --i;
            --j;
        }
        else if (table[(i - 1) * w + j] >= table[i * w + j - 1])
            --i;
        else
            --j;
    }
    foreach (k; 0 .. pairs.length / 2)
    {
        auto t = pairs[k];
        pairs[k] = pairs[$ - 1 - k];
        pairs[$ - 1 - k] = t;
    }
    return pairs;
}

/// The scale-guard fallback: match equal keys at equal positions only.
private Pairing[] positionalPairs(in string[] a, in string[] b) @safe
{
    Pairing[] pairs;
    foreach (i; 0 .. a.length < b.length ? a.length : b.length)
        if (a[i] == b[i])
            pairs ~= Pairing(i, i);
    return pairs;
}

/// A block's identity for alignment: its kind and its normalized text, so
/// re-indentation and re-wrapping do not make a block look new.
private string blockKey(in MdBlock blk, scope const(char)[] src) @safe
{
    import std.conv : to;

    const text = blk.span.end <= src.length && blk.span.start <= blk.span.end
        ? src[blk.span.start .. blk.span.end] : "";
    // The kind prefix keeps a heading and a paragraph of the same words
    // from matching each other.
    return blk.kind.to!string ~ ": " ~ normalizedText(text);
}

/// Similarity of two keys as the ratio of a character-level LCS to the longer
/// one, capped so a pathological pair cannot dominate the pass.
private double similarity(scope const(char)[] a, scope const(char)[] b) @safe
{
    enum size_t maxChars = 400;
    if (a.length == 0 || b.length == 0)
        return a.length == b.length ? 1.0 : 0.0;
    const x = a.length > maxChars ? a[0 .. maxChars] : a;
    const y = b.length > maxChars ? b[0 .. maxChars] : b;

    const w = y.length + 1;
    auto row = new uint[](w);
    auto prev = new uint[](w);
    foreach (i; 0 .. x.length)
    {
        prev[] = row[];
        foreach (j; 0 .. y.length)
            row[j + 1] = x[i] == y[j]
                ? prev[j] + 1
                : (prev[j + 1] > row[j] ? prev[j + 1] : row[j]);
    }
    const longer = x.length > y.length ? x.length : y.length;
    return cast(double) row[y.length] / longer;
}

@("md_diff.similarity.bounds")
@safe unittest
{
    assert(similarity("hello", "hello") == 1.0);
    assert(similarity("hello", "") == 0.0);
    assert(similarity("", "") == 1.0);
    assert(similarity("the quick brown fox", "the quick brown cat") > 0.7);
    assert(similarity("alpha", "zzzzz") == 0.0);
}

@("md_diff.lcsPairs.matchesInOrder")
@safe unittest
{
    // b was inserted, d removed: a/c/e are the common subsequence.
    const pairs = lcsPairs(["a", "c", "d", "e"], ["a", "b", "c", "e"]);
    assert(pairs.length == 3);
    assert(pairs[0] == Pairing(0, 0)); // a
    assert(pairs[1] == Pairing(1, 2)); // c
    assert(pairs[2] == Pairing(3, 3)); // e
}

private bool haveGrammars() @safe
{
    import std.process : environment;

    return environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length != 0;
}

@("md_diff.diffMarkdown.onlyTheEditedBlockIsDecorated")
@system unittest
{
    import sparkles.syntax.md.model : extractMarkdown;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    enum before = "# Title\n\nfirst paragraph\n\nsecond paragraph\n";
    enum after = "# Title\n\nfirst paragraph\n\nsecond paragraph edited\n";
    auto res = diffMarkdown(extractMarkdown(reg, before),
        extractMarkdown(reg, after));

    assert(res.decorations.length == 1, "one block changed, one decoration");
    const d = res.decorations[0];
    assert(d.status == MdDiffStatus.changed);
    assert(d.emphasis.length == 1, "the change is localized to a word");
    assert(res.doc.source[d.emphasis[0].start .. d.emphasis[0].end] == " edited");

    // The rendered tree is the NEW document: same blocks, nothing spliced in.
    assert(res.doc.root.children.length == 3);
}

@("md_diff.diffMarkdown.removedBlocksStayInPlace")
@system unittest
{
    import sparkles.syntax.md.model : extractMarkdown, MdBlockKind;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    enum before = "alpha\n\nbeta\n\ngamma\n";
    enum after = "alpha\n\ngamma\n";
    auto res = diffMarkdown(extractMarkdown(reg, before),
        extractMarkdown(reg, after));

    // Three blocks render: the survivor, the removal in its old position, and
    // the second survivor — a deletion the reviewer can see, not a gap.
    assert(res.doc.root.children.length == 3);
    const middle = res.doc.root.children[1];
    assert(res.lookup(middle.span.start).status == MdDiffStatus.removed);
    import std.string : strip;

    assert(res.doc.source[middle.span.start .. middle.span.end].strip == "beta");
    assert(res.decorations.length == 1);

    // An addition is the mirror image.
    auto grown = diffMarkdown(extractMarkdown(reg, after),
        extractMarkdown(reg, before));
    assert(grown.decorations.length == 1);
    assert(grown.decorations[0].status == MdDiffStatus.added);
}

@("md_diff.diffMarkdown.realignedTableLightsUpOneCell")
@system unittest
{
    import sparkles.syntax.md.model : extractMarkdown, MdBlockKind;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();

    // The motivating scenario, at the document level: every row's raw text
    // changed (the formatter widened the columns) and exactly one cell's
    // content did.
    enum before =
        "| a | b |\n| --- | --- |\n| one | two |\n| three | four |\n";
    enum after =
        "| a         | b        |\n| --------- | -------- |\n"
        ~ "| one       | two      |\n| three     | FOUR     |\n";

    auto res = diffMarkdown(extractMarkdown(reg, before),
        extractMarkdown(reg, after));

    // Not one decoration per row: the re-padding is invisible here, because a
    // row whose cells all matched is unchanged whatever its padding looks like.
    size_t cells;
    foreach (d; res.decorations)
    {
        assert(d.status == MdDiffStatus.changed);
        ++cells;
    }
    assert(cells == 1, "exactly one cell changed");

    const d = res.decorations[0];
    assert(res.doc.source[d.spanStart .. d.spanStart + 4] == "FOUR",
        "the decoration names the cell that changed");
}
