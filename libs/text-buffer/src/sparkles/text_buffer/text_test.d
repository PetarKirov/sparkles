/**
Generated tests for `Text` against a plain byte array (testing.md, "Generated
tests"). The unittest configuration selects small chunks and fan-out, so a few
hundred bytes already make trees several levels deep.
*/
module sparkles.text_buffer.text_test;

version (unittest):

import sparkles.base.text.seek : nextGraphemeBoundary, previousGraphemeBoundary;

import sparkles.text_buffer.node : allocatedNodes, liveNodes, maxChunk, minChunk;
import sparkles.text_buffer.summary : Affinity, measure, tokenAt, utf16Units;
import sparkles.text_buffer.text : ConversionStatus, LinePoint, Text;

/// A deterministic generator; failures print the seed and step through the
/// assertion's context.
struct Xorshift
{
    ulong state;

    size_t next(size_t bound) @safe pure nothrow @nogc
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return cast(size_t)(state % bound);
    }
}

static immutable string[] pieces = [
    "a", "bc", "xyz", " ", "\n", "\r\n", "\r", "é", "世", "\U0001F600",
    "\xE0\xA0", "\x80", "\xF0\x9F", "\xC0", "\U0001F1FA\U0001F1F8", "é",
    "0123456789", "line\n", "\r\r\n\n",
];

char[] randomBytes(ref Xorshift random, size_t pieceCount) @safe pure nothrow
{
    char[] result;
    foreach (_; 0 .. pieceCount)
        result ~= pieces[random.next(pieces.length)];
    return result;
}

/// Every observable property of `text` agrees with the model `bytes`.
void checkAgainst(in Text text, const(char)[] bytes) @safe pure nothrow
{
    text.checkInvariants();
    assert(text.length == bytes.length);
    assert(text == bytes);
    assert(text.summary == measure(bytes), "summary differs from a whole-text measure");

    // Token boundaries of the model, for the conversions.
    auto starts = new bool[bytes.length + 1];
    size_t scalars, units;
    auto scalarAt = new size_t[bytes.length + 1];
    auto utf16At = new size_t[bytes.length + 1];
    for (size_t i; i < bytes.length;)
    {
        starts[i] = true;
        scalarAt[i] = scalars;
        utf16At[i] = units;
        const token = tokenAt(bytes[i .. $]);
        ++scalars;
        units += utf16Units(token.scalar);
        i += token.length;
    }
    starts[bytes.length] = true;
    scalarAt[bytes.length] = scalars;
    utf16At[bytes.length] = units;

    // Chunk boundaries, judged from the model rather than the chunker.
    foreach (chunk; text.chunks)
        if (chunk.start != 0)
        {
            assert(starts[chunk.start], "a chunk boundary splits a token");
            assert(!(bytes[chunk.start - 1] == '\r' && bytes[chunk.start] == '\n'),
                "a chunk boundary splits CR LF");
        }

    size_t[] lineStarts = [0];
    foreach (i, c; bytes)
        if (c == '\n')
            lineStarts ~= i + 1;
    assert(text.lineCount == lineStarts.length);
    foreach (line, start; lineStarts)
    {
        assert(text.lineStart(line) == start);
        size_t end = line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : bytes.length;
        if (line + 1 < lineStarts.length && end > start && bytes[end - 1] == '\r')
            --end;
        assert(text.lineEnd(line) == end);
    }

    foreach (p; 0 .. bytes.length + 1)
    {
        size_t before = p;
        while (!starts[before])
            --before;
        size_t after = p;
        while (!starts[after])
            ++after;
        const exact = before == p;
        const status = exact ? ConversionStatus.exact : ConversionStatus.snapped;
        assert(text.snap(p, Affinity.before).value == before);
        assert(text.snap(p, Affinity.after).value == after);
        assert(text.scalarIndexOf(p, Affinity.before).value == scalarAt[before]);
        assert(text.scalarIndexOf(p, Affinity.after).value == scalarAt[after]);
        assert(text.scalarIndexOf(p).status == status);
        assert(text.utf16IndexOf(p, Affinity.after).value == utf16At[after]);
        if (exact)
        {
            const s = text.positionOfScalar(scalarAt[p]);
            assert(s.value == p && s.status == ConversionStatus.exact);
            const u = text.positionOfUtf16(utf16At[p]);
            assert(u.value == p && u.status == ConversionStatus.exact);
        }
        size_t line;
        while (line + 1 < lineStarts.length && lineStarts[line + 1] <= p)
            ++line;
        assert(text.lineOf(p) == line);
        const point = text.pointOf(p, Affinity.before);
        assert(point.point == LinePoint(text.lineOf(before), before - lineStarts[text.lineOf(before)]));
        if (exact) // every boundary round-trips, between CR and LF too
            assert(text.positionOfPoint(LinePoint(line, p - lineStarts[line])).value == p);
    }
    // A UTF-16 index inside a surrogate pair snaps to either side.
    foreach (p; 0 .. bytes.length)
        if (starts[p] && utf16At[p] + 1 < units && tokenAt(bytes[p .. $]).scalar >= 0x10000)
        {
            const inside = utf16At[p] + 1;
            assert(text.positionOfUtf16(inside, Affinity.before).value == p);
            assert(text.positionOfUtf16(inside, Affinity.after).value
                == p + tokenAt(bytes[p .. $]).length);
            assert(text.positionOfUtf16(inside).status == ConversionStatus.snapped);
        }
    assert(text.scalarIndexOf(bytes.length + 1).status == ConversionStatus.outOfRange);
    assert(text.positionOfScalar(scalars + 1).status == ConversionStatus.outOfRange);
    assert(text.positionOfPoint(LinePoint(lineStarts.length, 0)).status
        == ConversionStatus.outOfRange);
    const pastFeed = lineStarts.length > 1 ? lineStarts[1] : bytes.length + 1;
    assert(text.positionOfPoint(LinePoint(0, pastFeed)).status
        == ConversionStatus.outOfRange);
}

/// Chunk walks in both directions from every position reassemble the text.
void checkChunkWalks(in Text text, const(char)[] bytes) @safe pure nothrow
{
    foreach (p; 0 .. bytes.length + 1)
    {
        char[] forward;
        size_t expectedStart = size_t.max;
        foreach (chunk; text.chunks(p))
        {
            if (expectedStart == size_t.max)
                assert(chunk.start <= p && (p < chunk.start + chunk.bytes.length));
            else
                assert(chunk.start == expectedStart);
            forward ~= chunk.bytes;
            expectedStart = chunk.start + chunk.bytes.length;
        }
        if (p < bytes.length)
            assert(forward == bytes[$ - forward.length .. $] && expectedStart == bytes.length);
        else
            assert(forward.length == 0);

        char[] backward;
        size_t expectedEnd = size_t.max;
        foreach (chunk; text.chunksBackward(p))
        {
            const end = chunk.start + chunk.bytes.length;
            if (expectedEnd == size_t.max)
                assert(chunk.start < p && p <= end);
            else
                assert(end == expectedEnd);
            backward = chunk.bytes ~ backward;
            expectedEnd = chunk.start;
        }
        if (p > 0)
            assert(backward == bytes[0 .. backward.length] && expectedEnd == 0
                && backward.length >= p);
        else
            assert(backward.length == 0);
    }
}

@("Text.model.randomEdits")
@safe pure nothrow
unittest
{
    foreach (seed; [0x9E3779B97F4A7C15UL, 0xD1B54A32D192ED03UL, 0x8CB92BA72F3D8DD7UL])
    {
        auto random = Xorshift(seed);
        Text text;
        char[] model;
        // Every version, kept alive, must keep its contents (TXB-TEXT2).
        Text[] versions;
        char[][] models;
        foreach (step; 0 .. 120)
        {
            const op = random.next(4);
            if (op == 0 || model.length == 0)
            {
                const at = random.next(model.length + 1);
                const inserted = randomBytes(random, 1 + random.next(12));
                text = text.replace(at, at, inserted);
                model = model[0 .. at] ~ inserted ~ model[at .. $];
            }
            else if (op == 1)
            {
                const from = random.next(model.length + 1);
                const to = from + random.next(model.length - from + 1);
                const inserted = randomBytes(random, random.next(3));
                text = text.replace(from, to, inserted);
                model = model[0 .. from] ~ inserted ~ model[to .. $];
            }
            else if (op == 2)
            {
                const from = random.next(model.length + 1);
                const to = from + random.next(model.length - from + 1);
                text = text.slice(from, to);
                model = model[from .. to].dup;
            }
            else
            {
                auto other = Text(randomBytes(random, random.next(20)));
                char[] otherModel;
                foreach (chunk; other.chunks)
                    otherModel ~= chunk.bytes;
                if (random.next(2))
                {
                    text = text.append(other);
                    model = model ~ otherModel;
                }
                else
                {
                    text = other.append(text);
                    model = otherModel ~ model;
                }
            }
            checkAgainst(text, model);
            if (step % 10 == 0)
            {
                versions ~= text;
                models ~= model.dup;
            }
        }
        foreach (i, v; versions)
        {
            assert(v == models[i]);
            v.checkInvariants();
        }
        checkChunkWalks(text, model);
    }
}

/// Edge cases a generator reaches rarely (testing.md, "Boundary examples").
@("Text.boundaryExamples")
@safe pure nothrow
unittest
{
    checkAgainst(Text.init, "");
    checkAgainst(Text(""), "");
    char[maxChunk] full = 'x';
    checkAgainst(Text(full[]), full[]);

    // A CR LF split by an edit in its middle stays one pair once rejoined.
    auto crlf = Text("ab\r\ncd");
    checkAgainst(crlf.replace(3, 3, "X"), "ab\rX\ncd");
    checkAgainst(crlf.replace(3, 3, "X").replace(3, 4, ""), "ab\r\ncd");

    // A 4-byte sequence straddling where the chunker would otherwise cut.
    char[] straddle;
    foreach (i; 0 .. maxChunk - 2)
        straddle ~= 'y';
    straddle ~= "\U0001F600";
    foreach (i; 0 .. 2 * minChunk)
        straddle ~= 'z';
    checkAgainst(Text(straddle), straddle);

    // A malformed lead joins a continuation inserted after it.
    auto lead = Text("ab\xE0");
    checkAgainst(lead.append(Text("\xA0\x80cd")), "ab\xE0\xA0\x80cd");
    checkAgainst(lead.replace(0, 0, "\xA0"), "\xA0ab\xE0");

    // Insertion and deletion at the same position, at 0 and at the end.
    auto t = Text("hello world, hello text");
    checkAgainst(t.replace(0, 0, ">>"), ">>hello world, hello text");
    checkAgainst(t.replace(t.length, t.length, "<<"), "hello world, hello text<<");
    checkAgainst(t.replace(5, 5, "").replace(5, 6, ""), "helloworld, hello text");
}

/// An edit allocates O(log n + (m + k) / minChunk) nodes, and every other
/// node of the result is shared (TXB-TEXT6).
@("Text.sharingBound")
@safe pure nothrow
unittest
{
    char[] model;
    auto random = Xorshift(7);
    foreach (_; 0 .. 4000)
        model ~= pieces[random.next(pieces.length)];
    const text = Text(model);
    size_t height;
    for (size_t leaves = 1; leaves < text.summary.bytes / minChunk; leaves *= 2)
        ++height;
    foreach (step; 0 .. 200)
    {
        const from = random.next(model.length + 1);
        const to = from + random.next(model.length - from + 1 < 64 ? model.length - from + 1 : 64);
        const inserted = randomBytes(random, random.next(8));
        size_t before;
        debug before = allocatedNodes;
        const edited = text.replace(from, to, inserted);
        size_t allocated;
        debug allocated = allocatedNodes - before;
        // Four joins of logarithmic cost, three rebuilt seams, two sliced ends.
        const bound = 12 * (height + 2) + 3 * (to - from + inserted.length) / minChunk + 16;
        assert(allocated <= bound, "an edit copied more than its path");
        assert(edited == model[0 .. from] ~ inserted ~ model[to .. $]);
    }
}

@("Text.equality.sharedAndUnshared")
@safe pure nothrow
unittest
{
    char[] model;
    foreach (i; 0 .. 300)
        model ~= "abcdefghij"[i % 10];
    const a = Text(model);
    const b = a;
    assert(a == b, "a shared root compares equal without reading");
    const c = Text(model);
    assert(a == c, "equal bytes in unshared trees");
    // Partly shared: the same edit applied to two copies shares most leaves.
    const d = a.replace(10, 11, "Z");
    const e = c.replace(10, 11, "Z");
    assert(d == e && d != a);
    // Different chunking of the same bytes still compares equal.
    const f = Text(model[0 .. 150]).append(Text(model[150 .. $]));
    assert(f == a);
    assert(a.replace(299, 300, "q") != a);
}


/// Every node is freed once the last text holding it goes (TXB-OWN1).
@("Text.release.returnsToBaseline")
@safe pure nothrow @nogc
unittest
{
    size_t baseline;
    debug baseline = liveNodes;
    {
        auto text = Text("the quick brown fox jumps over the lazy dog, twice over");
        auto other = text.replace(4, 9, "slow").append(text).slice(3, 60);
        auto third = other;
        third = third.replace(0, 0, "!");
        assert(other != third);
    }
    size_t live;
    debug live = liveNodes;
    assert(live == baseline, "a node outlived every text");
}

/// `Text` is a chunked source: the base steppers walk it without copying.
@("Text.chunkedSource.steppers")
@safe pure nothrow @nogc
unittest
{
    auto text = Text("ab\U0001F1FA\U0001F1F8\U0001F1E6\U0001F1E7cd éf");
    assert(nextGraphemeBoundary(text, 2) == 10);
    assert(previousGraphemeBoundary(text, 18) == 10);
    assert(nextGraphemeBoundary(text, 22) == 24, "e + combining acute is one cluster");
}

/// Copies made and dropped on several threads leave counts balanced (TXB-OWN2).
@("Text.threads.sharedCounts")
@system
unittest
{
    import core.thread : Thread;

    auto text = Text("shared between threads, copied on each of them many times over");
    shared(Text)* address = cast(shared(Text)*) &text;
    Thread[4] threads;
    foreach (ref thread; threads)
    {
        thread = new Thread({
            auto source = cast(Text*) address;
            foreach (_; 0 .. 10_000)
            {
                auto copy = *source;
                auto second = copy;
            }
        });
        thread.start();
    }
    foreach (thread; threads)
        thread.join();
    import sparkles.text_buffer.node : unshared;
    assert(unshared(text.rootNode), "a count was lost or leaked");
}

/// Every public operation compiles under the full attribute set (TXB-OWN5).
@("Text.attributes")
@safe pure nothrow @nogc
unittest
{
    auto text = Text("abc\ndef");
    auto edited = text.replace(1, 2, "XY").append(text).slice(1, 8);
    char[7] copy;
    edited.copyTo(0, 7, copy[]);
    assert(edited == copy[]);
    assert(edited == "XYc\ndef");
    assert(edited.lineCount == 2 && edited.lineStart(1) == 4);
    assert(edited.pointOf(6).point == LinePoint(1, 2));
    assert(edited.positionOfPoint(LinePoint(1, 1)).value == 5);
    foreach (chunk; edited.chunksBackward(edited.length))
        assert(chunk.bytes.length);
}

/// `==` reads only the bytes of subtrees the operands do not share (TXB-TEXT7).
@("Text.equality.skipsSharedSubtrees")
@safe pure nothrow
unittest
{
    import sparkles.text_buffer.text : bytesCompared;

    char[] model;
    foreach (i; 0 .. 5000)
        model ~= "abcdefghij"[i % 10];
    const a = Text(model);
    // Two separately built trees that share every subtree but the edited path.
    const d = a.replace(2500, 2501, "Z");
    const e = d.slice(0, 2500).append(Text("Z")).append(d.slice(2501, d.length));
    size_t before;
    debug before = bytesCompared;
    assert(d == e);
    size_t read;
    debug read = bytesCompared - before;
    assert(read < 20 * maxChunk, "equality read shared subtrees");

    // Unshared equal texts are read in full.
    const fresh = Text(model);
    debug before = bytesCompared;
    assert(fresh == a);
    debug read = bytesCompared - before;
    assert(read == model.length);
}

/// A chunk range owns a reference: reassigning the text it came from leaves
/// it readable, and dropping both frees every node.
@("Text.chunks.outliveReassignment")
@safe pure nothrow @nogc
unittest
{
    size_t baseline;
    debug baseline = liveNodes;
    {
        auto text = Text("a text long enough to span several chunks of the tree");
        auto forward = text.chunks;
        auto backward = text.chunksBackward(text.length);
        text = Text.init;
        char[64] joined;
        size_t n;
        foreach (chunk; forward)
        {
            joined[n .. n + chunk.bytes.length] = chunk.bytes;
            n += chunk.bytes.length;
        }
        assert(joined[0 .. n] == "a text long enough to span several chunks of the tree");
        size_t back;
        foreach (chunk; backward)
            back += chunk.bytes.length;
        assert(back == n);
    }
    size_t live;
    debug live = liveNodes;
    assert(live == baseline);
}

/// The position between CR and LF converts both ways.
@("Text.point.betweenCrAndLf")
@safe pure nothrow @nogc
unittest
{
    const text = Text("a\r\nb");
    const point = text.pointOf(2);
    assert(point.point == LinePoint(0, 2) && point.status == ConversionStatus.exact);
    const back = text.positionOfPoint(point.point);
    assert(back.value == 2 && back.status == ConversionStatus.exact);
    assert(text.positionOfPoint(LinePoint(0, 3)).status == ConversionStatus.outOfRange);
    assert(text.lineEnd(0) == 1);
}
