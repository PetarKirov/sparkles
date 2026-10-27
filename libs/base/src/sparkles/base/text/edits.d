/**
 * Byte-range text edits: validate a list, stream the edited text, map offsets.
 *
 * A $(LREF TextEdit) pairs a `TextSpan` range of an original text with a
 * borrowed replacement: an empty range is an insertion, an empty replacement
 * a deletion. The replacement is borrowed, not owned — the producer keeps it
 * alive in its own buffer — so a list of edits costs one small record per
 * change and no copies.
 *
 * $(LREF validateEdits) checks a list against the source length (TXE1),
 * $(LREF writeEdited) streams the edited text into any output range (TXE2,
 * TXE3), and $(LREF mapOffset) carries an original offset into the result
 * (TXE4). Validation and mapping are `@safe pure nothrow @nogc`; writing
 * infers its attributes from the writer (TXE5). The contract lives in
 * `docs/specs/base/text/edits.md`.
 */
module sparkles.base.text.edits;

import expected : Expected, err, ok;
import std.range.primitives : put;

import sparkles.base.text.errors : NoGcHook;
import sparkles.base.text.span : TextSpan;

/// One replacement: `range` of the original becomes `replacement`.
struct TextEdit
{
    /// The replaced byte range of the original; empty for an insertion.
    TextSpan range;
    /// The borrowed replacement text; empty for a deletion.
    const(char)[] replacement;

    /// An insertion of `text` at offset `at`.
    static TextEdit insert(uint at, return scope const(char)[] text) @safe pure nothrow @nogc
        => TextEdit(TextSpan(at, at), text);

    /// A deletion of `span`.
    static TextEdit remove(TextSpan span) @safe pure nothrow @nogc
        => TextEdit(span, null);

    /// A replacement of `span` by `text`.
    static TextEdit replace(TextSpan span, return scope const(char)[] text) @safe pure nothrow @nogc
        => TextEdit(span, text);

    /// Whether this edit inserts without replacing anything.
    bool isInsertion() const @safe pure nothrow @nogc => range.empty;
}

///
@("text.edits.TextEdit.factories")
@safe pure nothrow @nogc
unittest
{
    const ins = TextEdit.insert(3, "x");
    assert(ins.isInsertion && ins.range == TextSpan(3, 3) && ins.replacement == "x");

    const del = TextEdit.remove(TextSpan(1, 4));
    assert(!del.isInsertion && del.replacement.length == 0);

    const rep = TextEdit.replace(TextSpan(0, 2), "ab");
    assert(rep.range == TextSpan(0, 2) && rep.replacement == "ab");
}

/// Why a list of edits is invalid (TXE1).
enum EditViolationCode : ubyte
{
    /// The edit's range is the invalid `TextSpan` sentinel.
    invalidRange,
    /// The edit's range ends past the source.
    outOfBounds,
    /// The edit starts before the previous edit does.
    unsorted,
    /// The edit starts before the previous edit's range ends.
    overlap,
    /// An insertion follows the non-empty range that starts at its offset.
    insertionAfterRange,
}

/// The first offending edit of a list: `index` names it, and for the
/// pairwise codes (`unsorted`, `overlap`, `insertionAfterRange`) the other
/// edit of the pair is `index - 1`.
struct EditViolation
{
    EditViolationCode code; /// what is wrong
    size_t index;           /// the offending edit's position in the list
}

/// The result of $(LREF validateEdits): success, or the first violation.
alias EditValidation = Expected!(void, EditViolation, NoGcHook);

/**
Validates `edits` against a source of `sourceLength` bytes (TXE1).

A list is valid when every range is a valid span within the source, starts
are non-decreasing, each range ends no later than the next one starts, and
at one start every insertion precedes the non-empty range that starts
there. Several insertions at one offset are valid (TXE3).

Returns: success, or the first offending edit by index.
*/
EditValidation validateEdits(size_t sourceLength, scope const TextEdit[] edits)
    @safe pure nothrow @nogc
{
    foreach (i, ref e; edits)
    {
        if (!e.range.isValid)
            return violation(EditViolationCode.invalidRange, i);
        if (e.range.endOffset > sourceLength)
            return violation(EditViolationCode.outOfBounds, i);
        if (i == 0)
            continue;
        const prev = edits[i - 1].range;
        if (e.range.startOffset < prev.startOffset)
            return violation(EditViolationCode.unsorted, i);
        if (e.range.startOffset == prev.startOffset && e.range.empty && !prev.empty)
            return violation(EditViolationCode.insertionAfterRange, i);
        if (prev.endOffset > e.range.startOffset)
            return violation(EditViolationCode.overlap, i);
    }
    return ok!(EditViolation, NoGcHook)();
}

private EditValidation violation(EditViolationCode code, size_t index) @safe pure nothrow @nogc
    => err!(void, NoGcHook)(EditViolation(code, index));

///
@("text.edits.validateEdits.rules")
@safe pure nothrow @nogc
unittest
{
    // Insertions before and after a range, and two at one offset: valid.
    const TextEdit[4] good = [
        TextEdit.insert(2, "a"), TextEdit.insert(2, "b"),
        TextEdit.replace(TextSpan(2, 4), "c"), TextEdit.insert(4, "d"),
    ];
    assert(!validateEdits(6, good[]).hasError);
    assert(!validateEdits(6, null).hasError);

    static void rejects(size_t len, scope const TextEdit[] edits,
        EditViolationCode code, size_t index) @safe pure nothrow @nogc
    {
        const r = validateEdits(len, edits);
        assert(r.hasError);
        assert(r.error.code == code && r.error.index == index);
    }

    const TextEdit[1] invalid = [TextEdit(TextSpan.init, "x")];
    rejects(6, invalid[], EditViolationCode.invalidRange, 0);

    const TextEdit[2] past = [TextEdit.insert(0, "x"), TextEdit.remove(TextSpan(5, 7))];
    rejects(6, past[], EditViolationCode.outOfBounds, 1);

    const TextEdit[2] unsorted = [TextEdit.insert(3, "x"), TextEdit.insert(1, "y")];
    rejects(6, unsorted[], EditViolationCode.unsorted, 1);

    const TextEdit[2] overlap = [TextEdit.remove(TextSpan(1, 4)), TextEdit.insert(3, "y")];
    rejects(6, overlap[], EditViolationCode.overlap, 1);

    const TextEdit[2] twoRanges = [TextEdit.remove(TextSpan(1, 4)), TextEdit.remove(TextSpan(1, 2))];
    rejects(6, twoRanges[], EditViolationCode.overlap, 1);

    const TextEdit[2] late = [TextEdit.remove(TextSpan(1, 4)), TextEdit.insert(1, "y")];
    rejects(6, late[], EditViolationCode.insertionAfterRange, 1);
}

/**
Writes `source` with `edits` applied into `writer` (TXE2, TXE3).

Emits, in order, the source before the first range, its replacement, the
source between ranges, and so on, then the source after the last range.
Insertions at one offset apply in list order. Attributes are inferred from
the writer, so writing into a `@safe pure nothrow @nogc` output range keeps
them.

Params:
    writer = any output range of `char`
    source = the original text
    edits = a list valid for `source` (see $(LREF validateEdits))
*/
void writeEdited(Writer)(ref Writer writer, scope const(char)[] source,
    scope const TextEdit[] edits)
in (!validateEdits(source.length, edits).hasError, "writeEdited: invalid edit list")
{
    size_t cursor;
    foreach (ref e; edits)
    {
        put(writer, source[cursor .. e.range.startOffset]);
        put(writer, e.replacement);
        cursor = e.range.endOffset;
    }
    put(writer, source[cursor .. $]);
}

///
@("text.edits.writeEdited.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkWriter;

    static immutable TextEdit[4] edits = [
        TextEdit.insert(0, "<"), TextEdit.replace(TextSpan(4, 9), "slow"),
        TextEdit.insert(10, "red "), TextEdit.remove(TextSpan(13, 19)),
    ];
    checkWriter!((ref b) => writeEdited(b, "the quick fox jumps", edits[]))(
        "<the slow red fox");
}

@("text.edits.writeEdited.sameOffsetInsertions")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkWriter;

    // TXE3: insertions at one offset apply in list order, around a range.
    static immutable TextEdit[4] edits = [
        TextEdit.insert(1, "1"), TextEdit.insert(1, "2"),
        TextEdit.replace(TextSpan(1, 2), "B"), TextEdit.insert(2, "3"),
    ];
    checkWriter!((ref b) => writeEdited(b, "abc", edits[]))("a12B3c");
}

/// Where an offset lands among insertions that apply at it (TXE4).
enum InsertionBias : ubyte
{
    /// After every insertion at the offset — the default.
    afterInsertions,
    /// Before every insertion at the offset.
    beforeInsertions,
}

/**
Maps an offset of the original through `edits` into the edited text (TXE4).

Offsets before a range shift by the accumulated length change; an offset
inside a replaced range maps to the same distance into its replacement,
clamped to the replacement's end. At an offset where insertions apply the
image lands after all of them, or before them with
`InsertionBias.beforeInsertions`. The mapping is monotonic.

Params:
    edits = a valid list (see $(LREF validateEdits))
    offset = an offset of the original
    bias = where an offset lands among insertions at it
*/
uint mapOffset(scope const TextEdit[] edits, uint offset,
    InsertionBias bias = InsertionBias.afterInsertions) @safe pure nothrow @nogc
{
    long delta;
    foreach (ref e; edits)
    {
        const start = e.range.startOffset;
        if (offset < start)
            break;
        if (offset == start && e.range.empty && bias == InsertionBias.beforeInsertions)
            break;
        const newLen = e.replacement.length;
        if (offset < e.range.endOffset)
        {
            const into = offset - start;
            return cast(uint) (start + delta + (into < newLen ? into : newLen));
        }
        delta += cast(long) newLen - cast(long) e.range.length;
    }
    return cast(uint) (offset + delta);
}

///
@("text.edits.mapOffset.basic")
@safe pure nothrow @nogc
unittest
{
    // "abcdef" becomes "a^XYef!": an insertion before the replaced "bcd",
    // and one at the end.
    static immutable TextEdit[3] edits = [
        TextEdit.insert(1, "^"), TextEdit.replace(TextSpan(1, 4), "XY"),
        TextEdit.insert(6, "!"),
    ];
    assert(mapOffset(edits[], 0) == 0);
    assert(mapOffset(edits[], 1) == 2);   // past the insertion, into "XY"
    assert(mapOffset(edits[], 1, InsertionBias.beforeInsertions) == 1);
    assert(mapOffset(edits[], 2) == 3);   // one into the replacement
    assert(mapOffset(edits[], 3) == 4);   // clamped to the replacement's end
    assert(mapOffset(edits[], 4) == 4);   // 'e'
    assert(mapOffset(edits[], 6) == 7);   // after the trailing insertion
    assert(mapOffset(edits[], 6, InsertionBias.beforeInsertions) == 6);
}

version (unittest)
{
    // A small deterministic PRNG (xorshift32) for the property tests.
    private struct XorShift
    {
        uint state = 0x9E3779B9;

        uint next() @safe pure nothrow @nogc
        {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            return state;
        }

        uint below(uint n) @safe pure nothrow @nogc => n ? next() % n : 0;
    }

    private static immutable string[4] replacements = ["", "x", "yz", "uvw"];

    // A valid list over a source of `len` bytes, built left to right.
    private size_t generateValid(ref XorShift rng, uint len, ref TextEdit[8] edits)
        @safe pure nothrow @nogc
    {
        size_t n;
        uint at = 0;
        while (n < edits.length && at <= len && rng.below(4) != 0)
        {
            at += rng.below(3);
            if (at > len)
                break;
            const end = at + rng.below(len - at + 1 < 4 ? len - at + 1 : 4);
            edits[n++] = TextEdit(TextSpan(at, end), replacements[rng.below(4)]);
            at = end;
        }
        return n;
    }

    // Arbitrary, usually invalid, lists.
    private size_t generateAny(ref XorShift rng, uint len, ref TextEdit[8] edits)
        @safe pure nothrow @nogc
    {
        const n = rng.below(6);
        foreach (i; 0 .. n)
        {
            if (rng.below(16) == 0)
            {
                edits[i] = TextEdit(TextSpan.init, "x");
                continue;
            }
            const s = rng.below(len + 3);
            edits[i] = TextEdit(TextSpan(s, s + rng.below(4)), replacements[rng.below(4)]);
        }
        return n;
    }
}

@("text.edits.writeEdited.matchesConcatenation")
@safe pure
unittest
{
    import std.array : appender;

    // TXE2's oracle: a reference by concatenation over generated lists.
    enum source = "0123456789ab";
    XorShift rng;
    TextEdit[8] buf;
    foreach (round; 0 .. 2000)
    {
        const len = rng.below(cast(uint) source.length + 1);
        const src = source[0 .. len];
        const edits = buf[0 .. generateValid(rng, len, buf)];
        assert(!validateEdits(len, edits).hasError);

        string expected;
        size_t cursor;
        foreach (e; edits)
        {
            expected ~= src[cursor .. e.range.startOffset];
            expected ~= e.replacement;
            cursor = e.range.endOffset;
        }
        expected ~= src[cursor .. $];

        auto actual = appender!string;
        writeEdited(actual, src, edits);
        assert(actual[] == expected);
    }
}

@("text.edits.validateEdits.matchesPairwiseOracle")
@safe pure nothrow @nogc
unittest
{
    // TXE1 against an independent definition: the first index at which the
    // edit itself, or any pair it closes with an earlier edit, is bad.
    static bool pairOk(in TextEdit a, in TextEdit b) @safe pure nothrow @nogc
        => a.range.startOffset <= b.range.startOffset
            && a.range.endOffset <= b.range.startOffset
            && !(a.range.startOffset == b.range.startOffset && b.range.empty && !a.range.empty);

    XorShift rng;
    TextEdit[8] buf;
    size_t valid, invalid;
    foreach (round; 0 .. 4000)
    {
        const len = rng.below(10);
        const edits = buf[0 .. (round & 1) ? generateValid(rng, len, buf) : generateAny(rng, len, buf)];

        size_t firstBad = size_t.max;
        outer: foreach (j, ref b; edits)
        {
            if (!b.range.isValid || b.range.endOffset > len)
            {
                firstBad = j;
                break;
            }
            foreach (ref a; edits[0 .. j])
                if (!pairOk(a, b))
                {
                    firstBad = j;
                    break outer;
                }
        }

        const r = validateEdits(len, edits);
        if (firstBad == size_t.max)
        {
            assert(!r.hasError);
            valid++;
        }
        else
        {
            assert(r.hasError && r.error.index == firstBad);
            invalid++;
        }
    }
    assert(valid > 100 && invalid > 100);
}

@("text.edits.mapOffset.monotonicAndFaithful")
@safe pure
unittest
{
    import std.array : appender;

    // TXE4: images never invert, and by default a byte no range replaces
    // maps onto the same byte of the result.
    enum source = "0123456789ab";
    XorShift rng;
    TextEdit[8] buf;
    foreach (round; 0 .. 2000)
    {
        const len = rng.below(cast(uint) source.length + 1);
        const src = source[0 .. len];
        const edits = buf[0 .. generateValid(rng, len, buf)];
        auto sink = appender!string;
        writeEdited(sink, src, edits);
        const result = sink[];

        foreach (bias; [InsertionBias.afterInsertions, InsertionBias.beforeInsertions])
        {
            uint prev = 0;
            foreach (o; 0 .. len + 1)
            {
                const image = mapOffset(edits, o, bias);
                assert(image >= prev && image <= result.length);
                prev = image;

                bool replaced;
                foreach (e; edits)
                    replaced |= e.range.contains(o);
                if (bias == InsertionBias.afterInsertions && o < len && !replaced)
                    assert(result[image] == src[o]);
            }
            if (bias == InsertionBias.afterInsertions)
                assert(mapOffset(edits, len, bias) == result.length);
        }
    }
}
