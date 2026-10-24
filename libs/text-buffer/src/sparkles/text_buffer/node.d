/**
Reference-counted nodes of the summary tree and the persistent operations on
them.

A leaf holds a chunk of between `minChunk` and `maxChunk` bytes, the only
leaf of a text excepted; an internal node holds between `minFanout` and
`maxFanout` children of equal height, the root excepted, which holds at
least two. Every leaf is at the same depth. A node is never modified once
built, apart from its atomic reference count, so any number of trees may
share it.

Ownership: a function returning a `Node*` hands its caller one reference; a
`Node*` parameter documented as _consumed_ takes one from it, and any other is
borrowed.

Specification: `docs/specs/text-buffer/SPEC.md` (TXB-TEXT3, TXB-TEXT5,
TXB-TEXT6, TXB-OWN1–3).
*/
module sparkles.text_buffer.node;

import core.atomic : atomicLoad, atomicOp;

import sparkles.text_buffer.summary : TextSummary, measure, tokenAt;

version (SparklesTextBufferSmallNodes)
{
    package enum size_t minChunk = 8;
    package enum size_t maxChunk = 24;
    package enum size_t minFanout = 3;
    package enum size_t maxFanout = 6;
}
else
{
    package enum size_t minChunk = 128;
    package enum size_t maxChunk = 512;
    package enum size_t minFanout = 6;
    package enum size_t maxFanout = 12;
}

// A cut window of `maxChunk - 2 * minChunk + 1` offsets always holds a legal
// cut, because legal cuts are never more than 4 bytes apart (a 4-byte
// sequence, or CR LF between two of them).
static assert(minChunk >= 8 && maxChunk >= 2 * minChunk + 8);
// Splitting `maxFanout + 1` children gives two nodes of at least `minFanout`.
static assert(minFanout >= 2 && maxFanout >= 2 * minFanout - 1);

/// No tree is deeper than this: each level at least doubles the leaves.
package enum size_t maxDepth = 64;

package struct Node
{
    shared size_t refs = 1;
    TextSummary summary;
    size_t leaves;
    uint height;
    /// A leaf's byte count, or an internal node's child count.
    uint count;
}

version (unittest)
{
    /// Nodes this thread allocated and has not freed, and allocated in all.
    /// Thread-local, so tests running in parallel do not see each other.
    package size_t liveNodes;
    /// ditto
    package size_t allocatedNodes;
}

package @safe pure nothrow @nogc:

Node* allocate(size_t payload) @trusted
{
    import core.exception : onOutOfMemoryError;
    import core.memory : pureMalloc;

    auto node = cast(Node*) pureMalloc(Node.sizeof + payload);
    if (node is null)
        onOutOfMemoryError();
    *node = Node.init;
    version (unittest) debug
    {
        ++liveNodes;
        ++allocatedNodes;
    }
    return node;
}

/// A leaf's bytes. Valid while the caller holds a reference to `node`.
const(char)[] bytes(return scope const(Node)* node) @trusted
in (node.height == 0)
    => (cast(const(char)*)(node + 1))[0 .. node.count];

/// An internal node's children, borrowed from it.
inout(Node*)[] children(return scope inout(Node)* node) @trusted
in (node.height != 0)
    => (cast(inout(Node*)*)(node + 1))[0 .. node.count];

/// Add a reference to `node` and return it. `node` may be `const`: only its
/// count changes, and that is shared and atomic.
Node* retain(scope const(Node)* node) @trusted
{
    // The count makes the returned reference independent of the argument's
    // lifetime, so it leaves `scope` through an integer.
    auto mutable = cast(Node*) cast(size_t) node;
    if (mutable !is null)
        atomicOp!"+="(mutable.refs, 1);
    return mutable;
}

/// Drop a reference, freeing the node and releasing its children at zero.
/// Recursion follows the tree's height, never its size.
void release(Node* node) @trusted
{
    import core.memory : pureFree;

    if (node is null || atomicOp!"-="(node.refs, 1) != 0)
        return;
    if (node.height != 0)
        foreach (child; children(node))
            release(child);
    version (unittest) debug --liveNodes;
    pureFree(node);
}

/// Whether nothing else refers to `node`.
bool unshared(scope const(Node)* node) @trusted => atomicLoad((cast(Node*) node).refs) == 1;

Node* makeLeaf(scope const(char)[] content) @trusted
in (content.length && content.length <= uint.max)
{
    auto node = allocate(content.length);
    (cast(char*)(node + 1))[0 .. content.length] = content[];
    node.count = cast(uint) content.length;
    node.summary = measure(content);
    node.leaves = 1;
    return node;
}

/// A node over `list`, whose references it consumes.
Node* makeInternal(scope Node*[] list) @trusted
in (list.length >= 1 && list.length <= maxFanout)
{
    auto node = allocate(list.length * (Node*).sizeof);
    node.height = list[0].height + 1;
    node.count = cast(uint) list.length;
    node.summary = list[0].summary;
    node.leaves = list[0].leaves;
    foreach (child; list[1 .. $])
    {
        assert(child.height + 1 == node.height, "children differ in height");
        node.summary = node.summary ~ child.summary;
        node.leaves += child.leaves;
    }
    (cast(Node**)(node + 1))[0 .. list.length] = list[];
    return node;
}

/// One or two nodes of the same height, the result of rebuilding a node that
/// may have overflowed.
struct Pair
{
    Node* first;
    Node* second;
}

/// Nodes over `list` (consumed): one node, or two halves when it overflows.
Pair group(scope Node*[] list)
in (list.length >= 1 && list.length <= 2 * maxFanout)
{
    if (list.length <= maxFanout)
        return Pair(makeInternal(list));
    const half = list.length / 2;
    return Pair(makeInternal(list[0 .. half]), makeInternal(list[half .. $]));
}

/// A root over `pair` (consumed).
Node* rootOf(Pair pair)
{
    if (pair.second is null)
        return pair.first;
    Node*[2] list = [pair.first, pair.second];
    return makeInternal(list[]);
}

/// Whether `node` may sit below a root: a leaf, or full enough.
bool validBelowRoot(scope const(Node)* node) => node.height == 0 || node.count >= minFanout;

/// Merge two roots of equal height (consumed) into one or two nodes of that
/// height. Leaves are not merged: two leaves stay two.
Pair joinSame(Node* a, Node* b)
in (a.height == b.height)
{
    if (a.height == 0)
        return Pair(a, b);
    Node*[2 * maxFanout] list;
    size_t n;
    foreach (child; children(a))
        list[n++] = retain(child);
    foreach (child; children(b))
        list[n++] = retain(child);
    release(a);
    release(b);
    return group(list[0 .. n]);
}

/// Append the shorter tree `b` (consumed) on the right spine of `n` (consumed).
Pair insertRight(Node* n, Node* b)
in (n.height > b.height)
{
    Node*[maxFanout + 1] list;
    size_t count;
    const kids = children(n);
    foreach (child; kids[0 .. $ - 1])
        list[count++] = retain(child);
    auto last = retain(kids[$ - 1]);
    Pair tail;
    if (n.height == b.height + 1)
        tail = validBelowRoot(b) ? Pair(last, b) : joinSame(last, b);
    else
        tail = insertRight(last, b);
    list[count++] = tail.first;
    if (tail.second !is null)
        list[count++] = tail.second;
    release(n);
    return group(list[0 .. count]);
}

/// Prepend the shorter tree `a` (consumed) on the left spine of `n` (consumed).
Pair insertLeft(Node* a, Node* n)
in (n.height > a.height)
{
    Node*[maxFanout + 1] list;
    size_t count;
    const kids = children(n);
    auto first = retain(kids[0]);
    Pair head;
    if (n.height == a.height + 1)
        head = validBelowRoot(a) ? Pair(a, first) : joinSame(a, first);
    else
        head = insertLeft(a, first);
    list[count++] = head.first;
    if (head.second !is null)
        list[count++] = head.second;
    foreach (child; kids[1 .. $])
        list[count++] = retain(child);
    release(n);
    return group(list[0 .. count]);
}

/**
The tree whose leaves are those of `a` followed by those of `b` (both
consumed; either may be `null`). Costs O(|height(a) − height(b)| + 1) new
nodes. A leaf below the root must already hold at least `minChunk` bytes;
callers rebuild the leaves at a seam before joining.
*/
Node* join(Node* a, Node* b)
{
    if (a is null)
        return b;
    if (b is null)
        return a;
    if (a.height == b.height)
        return rootOf(joinSame(a, b));
    if (a.height > b.height)
        return rootOf(insertRight(a, b));
    return rootOf(insertLeft(a, b));
}

/// Caller-owned scratch memory outside the collector, freed on scope exit.
struct Scratch(T)
{
    private T* ptr;
    private size_t length;

    @disable this(this);

    this(size_t length) @trusted
    {
        import core.exception : onOutOfMemoryError;
        import core.memory : pureMalloc;

        if (length == 0)
            return;
        ptr = cast(T*) pureMalloc(length * T.sizeof);
        if (ptr is null)
            onOutOfMemoryError();
        this.length = length;
    }

    ~this() @trusted
    {
        import core.memory : pureFree;

        pureFree(ptr);
    }

    T[] slice() return scope @trusted => ptr[0 .. length];
}

/// The leaves of `root` with index in `[a, b)`, as a new tree sharing every
/// whole subtree inside the range. `root` is borrowed.
Node* sliceLeaves(scope const(Node)* root, size_t a, size_t b)
in (a <= b && (root is null || b <= root.leaves))
{
    if (a == b)
        return null;
    auto storage = Scratch!(Node*)(2 * maxFanout * (root.height + 1));
    auto pieces = storage.slice;
    size_t n;

    void collect(scope const(Node)* node, size_t from, size_t to)
    {
        if (from == 0 && to == node.leaves)
        {
            pieces[n++] = retain(node);
            return;
        }
        size_t offset;
        foreach (child; children(node))
        {
            const end = offset + child.leaves;
            if (end > from && offset < to)
                collect(child, from > offset ? from - offset : 0,
                    (to < end ? to : end) - offset);
            offset = end;
            if (offset >= to)
                break;
        }
    }

    collect(root, a, b);
    // Heights rise to a peak and fall again; folding each side towards the
    // peak keeps the joins' total cost logarithmic.
    size_t peak;
    foreach (i; 1 .. n)
        if (pieces[i].height > pieces[peak].height)
            peak = i;
    Node* left = pieces[0];
    foreach (i; 1 .. peak + 1)
        left = join(left, pieces[i]);
    Node* right;
    if (peak + 1 < n)
    {
        right = pieces[n - 1];
        foreach_reverse (i; peak + 1 .. n - 1)
            right = join(pieces[i], right);
    }
    return join(left, right);
}

/// Whether a chunk of `content` may end at `cut`: not inside a token (a
/// scalar or a malformed maximal subpart) and not between CR and LF.
/// `content` itself starts at a token boundary.
bool legalCut(scope const(char)[] content, size_t cut)
in (cut > 0 && cut < content.length)
{
    if (content[cut - 1] == '\r' && content[cut] == '\n')
        return false;
    if ((content[cut] & 0xC0) != 0x80)
        return true; // only a continuation byte can extend a token
    size_t q = cut;
    foreach (_; 0 .. 3)
    {
        if (q == 0)
            break;
        --q;
        if ((content[q] & 0xC0) != 0x80)
            return q + tokenAt(content[q .. $]).length <= cut;
    }
    return true; // four continuation bytes: the one at `cut` stands alone
}

/// A balanced tree over `content`, cut into legal chunks. Consumes nothing;
/// returns `null` for empty content.
Node* build(scope const(char)[] content)
{
    if (!content.length)
        return null;
    auto storage = Scratch!(Node*)(content.length / minChunk + 2);
    auto nodes = storage.slice;
    size_t n;
    size_t start;
    while (content.length - start > maxChunk)
    {
        const remaining = content.length - start;
        size_t cut = start + (maxChunk < remaining - minChunk ? maxChunk : remaining - minChunk);
        while (!legalCut(content, cut))
            --cut;
        assert(cut >= start + minChunk, "a legal cut always exists in the window");
        nodes[n++] = makeLeaf(content[start .. cut]);
        start = cut;
    }
    nodes[n++] = makeLeaf(content[start .. $]);
    return buildLevels(nodes[0 .. n]);
}

/// A balanced tree over `nodes` (consumed), all of one height, in order.
Node* buildLevels(scope Node*[] nodes)
in (nodes.length)
{
    size_t n = nodes.length;
    while (n > 1)
    {
        const groups = (n + maxFanout - 1) / maxFanout;
        size_t from;
        foreach (g; 0 .. groups)
        {
            const to = n * (g + 1) / groups;
            nodes[g] = makeInternal(nodes[from .. to]);
            from = to;
        }
        n = groups;
    }
    return nodes[0];
}

/// The leaf holding byte `offset`, or the last leaf at the end, with its
/// index and start offset.
struct LeafAt
{
    const(Node)* leaf;
    size_t index;
    size_t start;
}

LeafAt leafAt(return scope const(Node)* root, size_t offset)
in (root !is null && offset <= root.summary.bytes)
{
    auto node = root;
    LeafAt result;
    while (node.height != 0)
    {
        const kids = children(node);
        size_t i;
        while (i + 1 < kids.length && offset - result.start >= kids[i].summary.bytes)
        {
            result.start += kids[i].summary.bytes;
            result.index += kids[i].leaves;
            ++i;
        }
        node = kids[i];
    }
    result.leaf = node;
    return result;
}

/// The leaf with index `index`, and its start offset.
LeafAt leafByIndex(return scope const(Node)* root, size_t index)
in (root !is null && index < root.leaves)
{
    auto node = root;
    LeafAt result;
    while (node.height != 0)
    {
        foreach (child; children(node))
        {
            if (index - result.index < child.leaves)
            {
                node = child;
                break;
            }
            result.index += child.leaves;
            result.start += child.summary.bytes;
        }
    }
    result.leaf = node;
    return result;
}

/// Copy bytes `[from, to)` of the tree into `destination`.
void copyBytes(scope const(Node)* node, size_t from, size_t to, scope char[] destination)
in (to - from == destination.length && to <= node.summary.bytes)
{
    if (from == to)
        return;
    if (node.height == 0)
    {
        destination[] = bytes(node)[from .. to];
        return;
    }
    size_t offset;
    foreach (child; children(node))
    {
        const end = offset + child.summary.bytes;
        if (end > from && offset < to)
        {
            const a = from > offset ? from : offset;
            const b = to < end ? to : end;
            copyBytes(child, a - offset, b - offset, destination[a - from .. b - from]);
        }
        offset = end;
        if (offset >= to)
            break;
    }
}

/// Check every structural invariant of a tree, for tests.
void checkTree(scope const(Node)* root)
{
    if (root is null)
        return;
    assert(root.leaves == 1 || root.height != 0, "a root leaf is the only leaf");
    assert(root.height == 0 || root.count >= 2, "an internal root has two children");
    checkNode(root, root.leaves == 1, true);
}

private void checkNode(scope const(Node)* node, bool onlyLeaf, bool isRoot)
{
    if (node.height == 0)
    {
        const content = bytes(node);
        assert(content.length >= 1 && content.length <= maxChunk, "chunk too long");
        assert(onlyLeaf || content.length >= minChunk, "chunk too short");
        assert(node.summary == measure(content), "stale leaf summary");
        assert(node.leaves == 1);
        return;
    }
    assert(node.count <= maxFanout, "too many children");
    assert(isRoot || node.count >= minFanout, "too few children");
    TextSummary summary;
    size_t leaves;
    foreach (i, child; children(node))
    {
        assert(child.height + 1 == node.height, "uneven depth");
        checkNode(child, false, false);
        summary = i ? summary ~ child.summary : child.summary;
        leaves += child.leaves;
    }
    assert(summary == node.summary, "stale internal summary");
    assert(leaves == node.leaves, "stale leaf count");
}
