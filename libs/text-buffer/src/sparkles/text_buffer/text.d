/**
`Text`: an immutable UTF-8 text in a persistent summary tree.

Copying a text is O(1) and allocation-free; every "modifying" operation
returns a new text that shares all untouched subtrees with its arguments.
Positions are byte offsets. Lines end before their line feed, or before the
CR of a CR LF pair.

Specification: `docs/specs/text-buffer/SPEC.md` §2–3.
*/
module sparkles.text_buffer.text;

import sparkles.base.text.seek : SourceChunk, isChunkedSource;

import sparkles.text_buffer.node : LeafAt, Node, Scratch, build, bytes, checkTree, children, legalCut,
    copyBytes, join, leafAt, leafByIndex, maxDepth, maxFanout, release, retain, sliceLeaves;
import sparkles.text_buffer.summary : Affinity, TextSummary, tokenAt, utf16Units;

/// How a conversion resolved its input.
enum ConversionStatus : ubyte
{
    /// The input named a boundary of the target unit.
    exact,
    /// The input fell inside a unit and was moved to the side its affinity names.
    snapped,
    /// The input was beyond the text; `value` is meaningless.
    outOfRange,
}

/// The result of converting one coordinate into another.
struct Conversion
{
    size_t value;
    ConversionStatus status;

    bool ok() const scope @safe pure nothrow @nogc => status != ConversionStatus.outOfRange;
}

/// A line number and a byte offset inside that line, both from 0.
struct LinePoint
{
    size_t line;
    size_t column;
}

/// A `LinePoint` conversion result.
struct PointConversion
{
    LinePoint point;
    ConversionStatus status;

    bool ok() const scope @safe pure nothrow @nogc => status != ConversionStatus.outOfRange;
}

/**
An immutable byte sequence, normally UTF-8, held in a summary tree.

`Text` is a Regular value: copies are independent, `==` compares contents,
and copying is one atomic increment. It is the size of one pointer.
*/
struct Text
{
    private Node* root;

    private this(Node* root) @safe pure nothrow @nogc
    {
        this.root = root;
    }

    /// A text holding a copy of `content`.
    this(scope const(char)[] content) @safe pure nothrow @nogc
    {
        root = build(content);
    }

    /// Copying adds one reference; the copy shares every node.
    this(ref scope const Text other) @safe pure nothrow @nogc
    {
        root = retain(other.root);
    }

    /// ditto
    this(ref scope const Text other) const @safe pure nothrow @nogc
    {
        root = retain(other.root);
    }

    ~this() scope @safe pure nothrow @nogc
    {
        release(root);
    }

    /// Byte length.
    size_t length() const scope @safe pure nothrow @nogc => root ? root.summary.bytes : 0;

    /// ditto
    alias opDollar = length;

    /// The measures of the whole text.
    TextSummary summary() const scope @safe pure nothrow @nogc
        => root ? root.summary : TextSummary.init;

    /// Whether the text is empty.
    bool empty() const scope @safe pure nothrow @nogc => root is null;

    // ------------------------------------------------------------- editing

    /// Bytes `[from, to)` as a new text.
    Text slice(size_t from, size_t to) const scope @safe pure nothrow @nogc
    in (from <= to && to <= length, "slice out of range")
    {
        if (from == to)
            return Text.init;
        if (from == 0 && to == length)
            return Text(retain(root));
        const first = leafAt(root, from);
        const last = leafAt(root, to - 1);
        if (last.index - first.index <= 3)
            return gathered(from, to);
        // Rebuild two leaves at each end, so every new edge chunk holds at
        // least one whole old chunk and stays long enough.
        const headEnd = leafEnd(first.index + 1);
        const tailStart = leafByIndex(root, last.index - 1).start;
        auto head = gathered(from, headEnd);
        auto tail = gathered(tailStart, to);
        auto middle = sliceLeaves(root, first.index + 2, last.index - 1);
        return Text(join(join(head.take, middle), tail.take));
    }

    /// The concatenation of this text and `other`.
    Text append(in Text other) const scope @safe pure nothrow @nogc
    {
        if (root is null)
            return Text(retain(other.root));
        if (other.root is null)
            return Text(retain(root));
        // The two chunks at the seam are rebuilt together: a sequence or a
        // CR LF can only now be joined across it.
        const lastLeaf = leafByIndex(root, root.leaves - 1);
        const firstLeaf = leafByIndex(other.root, 0);
        const left = bytes(lastLeaf.leaf);
        const right = bytes(firstLeaf.leaf);
        auto storage = Scratch!char(left.length + right.length);
        auto seam = storage.slice;
        seam[0 .. left.length] = left[];
        seam[left.length .. $] = right[];
        auto prefix = sliceLeaves(root, 0, root.leaves - 1);
        auto suffix = sliceLeaves(other.root, 1, other.root.leaves);
        return Text(join(join(prefix, build(seam)), suffix));
    }

    /// ditto
    Text opBinary(string op : "~")(Text other) const => append(other);

    /// This text with bytes `[from, to)` replaced by `inserted`.
    Text replace(size_t from, size_t to, in Text inserted) const scope
        @safe pure nothrow @nogc
    in (from <= to && to <= length, "replace out of range")
        => slice(0, from).append(inserted).append(slice(to, length));

    /// ditto
    Text replace(size_t from, size_t to, scope const(char)[] inserted) const scope
        @safe pure nothrow @nogc
    in (from <= to && to <= length, "replace out of range")
        => replace(from, to, Text(inserted));

    // ----------------------------------------------------------- equality

    /// Byte-wise equality. Shared subtrees at the same offset are skipped.
    bool opEquals(in Text other) const scope @safe pure nothrow @nogc
    {
        if (root is other.root)
            return true;
        if (length != other.length)
            return false;
        return equalTrees(root, other.root);
    }

    /// ditto
    bool opEquals(scope const(char)[] content) const scope @safe pure nothrow @nogc
    {
        if (content.length != length)
            return false;
        size_t offset;
        foreach (chunk; chunks)
        {
            if (chunk.bytes != content[offset .. offset + chunk.bytes.length])
                return false;
            offset += chunk.bytes.length;
        }
        return true;
    }

    // ------------------------------------------------------- chunk access

    /// The chunk holding byte `offset < length`; makes `Text` a chunked
    /// source for `sparkles.base.text.seek`.
    SourceChunk chunkAt(size_t offset) const return scope @safe pure nothrow @nogc
    in (offset < length, "offset is outside the text")
    {
        const at = leafAt(root, offset);
        return SourceChunk(at.start, bytes(at.leaf));
    }

    /// The chunks in order, starting with the one holding byte `from`.
    ChunkRange!true chunks(size_t from = 0) const scope @safe pure nothrow @nogc
    in (from <= length)
        => ChunkRange!true(root, from);

    /// The chunks in reverse, starting with the one holding byte `before - 1`.
    ChunkRange!false chunksBackward(size_t before) const scope @safe pure nothrow @nogc
    in (before <= length)
        => ChunkRange!false(root, before);

    /// Copy bytes `[from, to)` into `destination`, which must fit them.
    void copyTo(size_t from, size_t to, scope char[] destination) const scope
        @safe pure nothrow @nogc
    in (from <= to && to <= length && destination.length == to - from)
    {
        if (root)
            copyBytes(root, from, to, destination);
    }

    /// Write the text's bytes to an output range.
    void toString(W)(ref W writer) const scope
    {
        import std.range.primitives : put;

        foreach (chunk; chunks)
            put(writer, chunk.bytes);
    }

    // -------------------------------------------------------- conversion

    /// The number of scalars before `position`.
    Conversion scalarIndexOf(size_t position, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
        => prefixMeasure!"scalars"(position, affinity);

    /// The number of UTF-16 code units before `position`.
    Conversion utf16IndexOf(size_t position, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
        => prefixMeasure!"utf16"(position, affinity);

    /// The position of the scalar with index `index`, or the end for the
    /// scalar count. Every scalar index names a boundary.
    Conversion positionOfScalar(size_t index) const scope @safe pure nothrow @nogc
        => positionOfMeasure!"scalars"(index, Affinity.before);

    /// The position of UTF-16 index `index`. An index between the two units
    /// of a surrogate pair snaps to the pair's start or end.
    Conversion positionOfUtf16(size_t index, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
        => positionOfMeasure!"utf16"(index, affinity);

    /// The line and in-line byte offset of `position`.
    PointConversion pointOf(size_t position, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
    {
        const snapped = snap(position, affinity);
        if (!snapped.ok)
            return PointConversion(status: ConversionStatus.outOfRange);
        const line = lineOf(snapped.value);
        return PointConversion(LinePoint(line, snapped.value - lineStart(line)), snapped.status);
    }

    /// The position of `point`, the inverse of `pointOf`. A column may reach
    /// the line's line feed, so the position between a CR and its LF is
    /// valid; one past it is out of range, and one inside a sequence snaps.
    Conversion positionOfPoint(LinePoint point, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
    {
        if (point.line >= lineCount)
            return Conversion(status: ConversionStatus.outOfRange);
        const start = lineStart(point.line);
        const last = point.line + 1 < lineCount ? lineStart(point.line + 1) - 1 : length;
        if (point.column > last - start)
            return Conversion(status: ConversionStatus.outOfRange);
        return snap(start + point.column, affinity);
    }

    /// `position` moved to a token boundary: the start of the scalar or
    /// malformed subpart holding it (`before`) or its end (`after`).
    Conversion snap(size_t position, Affinity affinity = Affinity.before) const scope
        @safe pure nothrow @nogc
    {
        if (position > length)
            return Conversion(status: ConversionStatus.outOfRange);
        if (position == length)
            return Conversion(position, ConversionStatus.exact);
        const at = leafAt(root, position);
        const content = bytes(at.leaf);
        for (size_t i; ; )
        {
            const next = i + tokenAt(content[i .. $]).length;
            if (at.start + i == position)
                return Conversion(position, ConversionStatus.exact);
            if (at.start + next > position)
                return Conversion(at.start + (affinity == Affinity.before ? i : next),
                    ConversionStatus.snapped);
            i = next;
        }
    }

    // ------------------------------------------------------------- lines

    /// The number of lines: one more than the number of line feeds.
    size_t lineCount() const scope @safe pure nothrow @nogc => summary.lineFeeds + 1;

    /// The position where line `line` starts.
    size_t lineStart(size_t line) const scope @safe pure nothrow @nogc
    in (line < lineCount, "no such line")
    {
        if (line == 0)
            return 0;
        // Descend to the leaf holding the line's preceding line feed.
        const(Node)* node = root;
        size_t start;
        size_t feeds;
        while (node.height != 0)
        {
            foreach (child; children(node))
            {
                if (feeds + child.summary.lineFeeds >= line)
                {
                    node = child;
                    break;
                }
                feeds += child.summary.lineFeeds;
                start += child.summary.bytes;
            }
        }
        foreach (i, c; bytes(node))
            if (c == '\n' && ++feeds == line)
                return start + i + 1;
        assert(0, "line feed counts are stale");
    }

    /// The position where line `line` ends: before its line feed, or before
    /// the CR of a CR LF.
    size_t lineEnd(size_t line) const scope @safe pure nothrow @nogc
    in (line < lineCount, "no such line")
    {
        if (line + 1 == lineCount)
            return length;
        const feed = lineStart(line + 1) - 1;
        return feed > lineStart(line) && byteAt(feed - 1) == '\r' ? feed - 1 : feed;
    }

    /// The line holding `position`; a line's end belongs to it.
    size_t lineOf(size_t position) const scope @safe pure nothrow @nogc
    in (position <= length)
        => prefixSummary(position).lineFeeds;

    /// The byte at `position < length`.
    char byteAt(size_t position) const scope @safe pure nothrow @nogc
    in (position < length)
    {
        const at = leafAt(root, position);
        return bytes(at.leaf)[position - at.start];
    }

    /// Check the tree's invariants and chunk boundaries, for tests.
    void checkInvariants() const scope @safe pure nothrow @nogc
    {
        checkTree(root);
        if (root is null)
            return;
        // Every chunk boundary must be a legal cut of the whole text.
        char[8] window;
        size_t previousEnd;
        foreach (chunk; chunks)
        {
            if (chunk.start != 0)
            {
                const from = chunk.start >= 4 ? chunk.start - 4 : 0;
                const to = chunk.start + 4 < length ? chunk.start + 4 : length;
                copyTo(from, to, window[0 .. to - from]);
                // The window may start inside a token; that only matters for
                // the bytes before the cut, which `legalCut` reads backwards
                // no further than three bytes.
                assert(legalCut(window[0 .. to - from], chunk.start - from),
                    "a chunk boundary splits a sequence or CR LF");
            }
            assert(chunk.start == previousEnd);
            previousEnd = chunk.start + chunk.bytes.length;
        }
        assert(previousEnd == length);
    }

    /// The node identity, for tests that measure sharing.
    package(sparkles.text_buffer) const(Node)* rootNode() const return scope
        @safe pure nothrow @nogc => root;

private:

    /// Move the root out, leaving this text empty.
    Node* take() @safe pure nothrow @nogc
    {
        auto node = root;
        root = null;
        return node;
    }

    /// Bytes `[from, to)` copied into a fresh tree.
    Text gathered(size_t from, size_t to) const scope @safe pure nothrow @nogc
    {
        auto storage = Scratch!char(to - from);
        auto content = storage.slice;
        copyBytes(root, from, to, content);
        return Text(build(content));
    }

    size_t leafEnd(size_t index) const scope @safe pure nothrow @nogc
    {
        const at = leafByIndex(root, index);
        return at.start + at.leaf.count;
    }

    /// The summary of bytes `[0, position)`; `position` is a token boundary.
    TextSummary prefixSummary(size_t position) const scope @safe pure nothrow @nogc
    {
        import sparkles.text_buffer.summary : measure;

        if (root is null || position == 0)
            return TextSummary.init;
        if (position == length)
            return root.summary;
        const(Node)* node = root;
        TextSummary prefix;
        size_t start;
        while (node.height != 0)
        {
            const kids = children(node);
            size_t i;
            while (i + 1 < kids.length && position - start >= kids[i].summary.bytes)
            {
                prefix = prefix ~ kids[i].summary;
                start += kids[i].summary.bytes;
                ++i;
            }
            node = kids[i];
        }
        return prefix ~ measure(bytes(node)[0 .. position - start]);
    }

    Conversion prefixMeasure(string field)(size_t position, Affinity affinity) const scope
    {
        const snapped = snap(position, affinity);
        if (!snapped.ok)
            return snapped;
        return Conversion(__traits(getMember, prefixSummary(snapped.value), field),
            snapped.status);
    }

    Conversion positionOfMeasure(string field)(size_t index, Affinity affinity) const scope
    {
        const total = __traits(getMember, summary, field);
        if (index > total)
            return Conversion(status: ConversionStatus.outOfRange);
        if (index == total)
            return Conversion(length, ConversionStatus.exact);
        const(Node)* node = root;
        size_t start;
        size_t counted;
        while (node.height != 0)
        {
            const kids = children(node);
            size_t i;
            while (i + 1 < kids.length
                && index - counted >= __traits(getMember, kids[i].summary, field))
            {
                counted += __traits(getMember, kids[i].summary, field);
                start += kids[i].summary.bytes;
                ++i;
            }
            node = kids[i];
        }
        const content = bytes(node);
        for (size_t i; i < content.length; )
        {
            const token = tokenAt(content[i .. $]);
            static if (field == "scalars")
                const units = 1;
            else
                const units = utf16Units(token.scalar);
            if (counted == index)
                return Conversion(start + i, ConversionStatus.exact);
            if (counted + units > index)
                return Conversion(start + (affinity == Affinity.before ? i : i + token.length),
                    ConversionStatus.snapped);
            counted += units;
            i += token.length;
        }
        return Conversion(start + content.length, ConversionStatus.exact);
    }
}

version (unittest)
{
    /// Bytes `==` has read on this thread, for tests of TXB-TEXT7.
    package size_t bytesCompared;
}

static assert(Text.sizeof <= 2 * (void*).sizeof, "TXB-OWN4: a Text is at most two pointers");
static assert(isChunkedSource!Text);

/// Whether the trees hold the same bytes; both have the same length.
private bool equalTrees(scope const(Node)* a, scope const(Node)* b) @safe pure nothrow @nogc
{
    // Each side is a stack of pending subtrees covering the rest of its text,
    // plus how much of the front leaf was consumed. Equal subtrees at the
    // same offset are skipped without reading them.
    static struct Side
    {
        const(Node)*[maxDepth * maxFanout] stack;
        size_t depth;
        size_t skip;

        void push(scope const(Node)* node) @safe pure nothrow @nogc { stack[depth++] = keep(node); }
        const(Node)* top() const scope @safe pure nothrow @nogc => stack[depth - 1];

        void expand() @safe pure nothrow @nogc
        {
            const node = stack[--depth];
            const kids = children(node);
            foreach_reverse (child; kids)
                push(child);
        }
    }

    Side left;
    Side right;
    left.push(a);
    right.push(b);
    while (left.depth && right.depth)
    {
        auto x = left.top;
        auto y = right.top;
        if (x is y && left.skip == 0 && right.skip == 0)
        {
            --left.depth;
            --right.depth;
            continue;
        }
        if (x.height != 0 || y.height != 0)
        {
            // Expand the taller side; on a tie, both.
            if (x.height >= y.height && x.height != 0)
                left.expand();
            if (y.height >= x.height && y.height != 0)
                right.expand();
            continue;
        }
        const p = bytes(x)[left.skip .. $];
        const q = bytes(y)[right.skip .. $];
        const n = p.length < q.length ? p.length : q.length;
        version (unittest) debug bytesCompared += n;
        if (p[0 .. n] != q[0 .. n])
            return false;
        left.skip += n;
        right.skip += n;
        if (left.skip == x.count)
        {
            --left.depth;
            left.skip = 0;
        }
        if (right.skip == y.count)
        {
            --right.depth;
            right.skip = 0;
        }
    }
    return true;
}

/// The chunks of a text in one direction, each with its start offset.
struct ChunkRange(bool forward)
{
    private const(Node)*[maxDepth] path;
    private uint[maxDepth] index;
    private size_t depth;
    private SourceChunk current;
    private bool done;
    // A reference to the walked tree: the nodes and chunks recorded above
    // stay alive for as long as the range does, however the text it came
    // from is reassigned meanwhile.
    private Text owner;


    private this(scope const(Node)* root, size_t offset) @safe pure nothrow @nogc
    {
        static if (forward)
            done = root is null || offset == root.summary.bytes;
        else
            done = root is null || offset == 0;
        if (done)
            return;
        owner = Text(retain(root));
        static if (!forward)
            --offset; // the chunk holding the byte before `offset`
        const(Node)* node = root;
        size_t start;
        while (node.height != 0)
        {
            const kids = children(node);
            uint i;
            while (i + 1 < kids.length && offset - start >= kids[i].summary.bytes)
            {
                start += kids[i].summary.bytes;
                ++i;
            }
            path[depth] = keep(node);
            index[depth] = i;
            ++depth;
            node = kids[i];
        }
        current = SourceChunk(start, keep(bytes(node)));
    }

    bool empty() const scope @safe pure nothrow @nogc => done;

    SourceChunk front() const return scope @safe pure nothrow @nogc
    in (!done)
        => current;

    void popFront() scope @safe pure nothrow @nogc
    in (!done)
    {
        static if (forward)
            const nextStart = current.start + current.bytes.length;
        // Climb to the nearest ancestor with a sibling in our direction.
        while (depth)
        {
            const kids = children(path[depth - 1]);
            static if (forward)
                const more = index[depth - 1] + 1 < kids.length;
            else
                const more = index[depth - 1] > 0;
            if (more)
                break;
            --depth;
        }
        if (depth == 0)
        {
            done = true;
            return;
        }
        static if (forward)
            ++index[depth - 1];
        else
            --index[depth - 1];
        const(Node)* node = children(path[depth - 1])[index[depth - 1]];
        while (node.height != 0)
        {
            const kids = children(node);
            path[depth] = keep(node);
            static if (forward)
                index[depth] = 0;
            else
                index[depth] = cast(uint)(kids.length - 1);
            node = kids[index[depth]];
            ++depth;
        }
        static if (forward)
            current = SourceChunk(nextStart, keep(bytes(node)));
        else
            current = SourceChunk(current.start - node.count, keep(bytes(node)));
    }
}

// A `ChunkRange` holds a reference to the tree it walks, so the nodes and
// chunks it records live as long as it does. dip1000 cannot see that through
// the path array; these stores are vouched for here, and the equality walk
// uses them for nodes its operands keep alive.
// They sit outside `ChunkRange` because a template's members infer `return`.
private const(Node)* keep(scope const(Node)* node) @trusted pure nothrow @nogc
    => cast(const(Node)*) cast(size_t) node;
private const(char)[] keep(scope const(char)[] chunk) @trusted pure nothrow @nogc
    => (cast(const(char)*) cast(size_t) chunk.ptr)[0 .. chunk.length];
