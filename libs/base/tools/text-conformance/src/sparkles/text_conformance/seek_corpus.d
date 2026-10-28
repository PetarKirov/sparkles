/** Boundary queries from every offset (TXT-SEG7–9) against the UCD corpora.
 *
 * Each record's expected boundaries come from the fixture; every offset of
 * its UTF-8 encoding is queried over chunkings of one to four bytes, so a
 * query that resumes without resynchronising, or that loses state at a chunk
 * edge, diverges.
 */
module sparkles.text_conformance.seek_corpus;

import std.format : format;
import sparkles.base.text.grapheme : GraphemeSpan, GraphemeStream, scanGraphemeStream;
import sparkles.base.text.seek : SourceChunk, nextGraphemeBoundary, previousGraphemeBoundary,
    isGraphemeBoundary, nextWordSegment, previousWordSegment;
import sparkles.base.text.utf : UtfMode, UtfStatus;

/// A source cut every `width` bytes.
struct ChunkedBytes
{
    const(char)[] bytes;
    size_t width;

    size_t length() const => bytes.length;

    SourceChunk chunkAt(size_t offset) const return scope
    {
        const start = offset / width * width;
        const end = start + width < bytes.length ? start + width : bytes.length;
        return SourceChunk(start, bytes[start .. end]);
    }
}

private size_t scalarStartOf(const size_t[] offsets, size_t at)
{
    size_t start;
    foreach (offset; offsets)
        if (offset <= at) start = offset;
    return start;
}

private size_t nextIn(const bool[] set, size_t a)
{
    foreach (i; a + 1 .. set.length)
        if (set[i]) return i;
    return set.length - 1;
}

private size_t previousIn(const bool[] set, size_t a)
{
    foreach_reverse (i; 0 .. a)
        if (set[i]) return i;
    return 0;
}

/// Byte-indexed boundary set from per-scalar fixture markers.
private bool[] byteSet(size_t length, const size_t[] offsets, const bool[] allowed)
{
    auto set = new bool[length + 1];
    foreach (i, offset; offsets)
        set[offset] = allowed[i];
    return set;
}

/// Mismatches of the grapheme queries at every offset; empty when all agree.
string[] graphemeSeekMismatches(const(char)[] bytes, const size_t[] offsets, const bool[] allowed)
{
    const set = byteSet(bytes.length, offsets, allowed);
    string[] mismatches;
    foreach (width; 1 .. 5)
    {
        auto source = ChunkedBytes(bytes, width);
        foreach (at; 0 .. bytes.length + 1)
        {
            const a = scalarStartOf(offsets, at);
            const next = a == bytes.length ? a : nextIn(set, a);
            const previous = previousIn(set, a);
            const isBoundary = set[at] && scalarStartOf(offsets, at) == at;
            const gotNext = nextGraphemeBoundary(source, at);
            const gotPrevious = previousGraphemeBoundary(source, at);
            const gotIs = isGraphemeBoundary(source, at);
            if (gotNext != next || gotPrevious != previous || gotIs != isBoundary)
                mismatches ~= format("chunk=%s at=%s next=%s/%s previous=%s/%s is=%s/%s",
                    width, at, gotNext, next, gotPrevious, previous, gotIs, isBoundary);
        }
    }
    return mismatches;
}

/// Mismatches of the word-segment queries, whose delimiters are the fixture's
/// word boundaries that are also grapheme boundaries.
string[] wordSeekMismatches(const(char)[] bytes, const size_t[] offsets, const bool[] allowed)
{
    auto set = byteSet(bytes.length, offsets, allowed);
    GraphemeStream stream;
    stream.reset(UtfMode.replacement);
    auto spans = new GraphemeSpan[bytes.length + 1];
    const scanned = scanGraphemeStream(stream, bytes, spans, true);
    if (scanned.status != UtfStatus.end)
        return [format("grapheme scan status=%s", scanned.status)];
    auto graphemeSet = new bool[bytes.length + 1];
    foreach (span; spans[0 .. scanned.written])
        graphemeSet[span.start] = true;
    graphemeSet[bytes.length] = true;
    foreach (i, ref b; set)
        b = b && graphemeSet[i];
    set[0] = set[bytes.length] = true;

    string[] mismatches;
    foreach (width; 1 .. 5)
    {
        auto source = ChunkedBytes(bytes, width);
        foreach (at; 0 .. bytes.length + 1)
        {
            const a = scalarStartOf(offsets, at);
            size_t forwardStart = a, forwardEnd = a;
            if (a != bytes.length)
            {
                forwardStart = set[a] ? a : previousIn(set, a);
                forwardEnd = nextIn(set, forwardStart);
            }
            size_t backwardStart, backwardEnd;
            if (a != 0)
            {
                backwardStart = previousIn(set, a);
                backwardEnd = nextIn(set, backwardStart);
            }
            const forward = nextWordSegment(source, at);
            const backward = previousWordSegment(source, at);
            if (forward.start != forwardStart || forward.end != forwardEnd
                || backward.start != backwardStart || backward.end != backwardEnd)
                mismatches ~= format("chunk=%s at=%s next=[%s,%s)/[%s,%s) previous=[%s,%s)/[%s,%s)",
                    width, at, forward.start, forward.end, forwardStart, forwardEnd,
                    backward.start, backward.end, backwardStart, backwardEnd);
        }
    }
    return mismatches;
}
