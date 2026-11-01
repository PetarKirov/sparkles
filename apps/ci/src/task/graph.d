/++
Task graphs ([SPEC §5, §9, §12](../../../../docs/specs/ci/task-dag/SPEC.md)):
a builder, validation, stable topological order, edge-condition resolution,
blocked propagation, and the dry-run projection.

A $(LREF TaskGraph) exists only validated. Its nodes are in presentation order
— by $(REF PresentationKey, task,model), then $(REF TaskId, task,model) —
whatever order they were added in, and a $(REF TaskIndex, task,model) is a
position in that order. Nothing here iterates an associative array or depends
on insertion order, completion order, or time.

Pure: no Event Horizon, process, or UI import.
+/
module task.graph;

import std.algorithm.sorting : sort;
import std.range.primitives : put;
import std.typecons : Nullable;



import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.wire_names : AnyFormat, WireCase;
import sparkles.base.text.writers : writeEnumMemberName, writeValue;

import task.action : writeActionSummary;
import task.model;

// ─────────────────────────────────────────────────────────────────────────────
// Index-level ordering, shared with the package graph
// ─────────────────────────────────────────────────────────────────────────────

/// An edge between dense indices: `to` waits on `from`.
struct IndexEdge
{
    uint from; ///
    uint to;   ///
}

/// The result of $(LREF stableTopologicalOrder): an order, or a cycle.
struct StableOrder
{
    /// Every index, prerequisites first, ties broken by the lower index.
    /// Empty when the graph is cyclic.
    uint[] order;
    /// The shortest cycle discovered, starting at its lowest member: each
    /// index waits on the one before it, and the first on the last.
    uint[] cycle;

    /// Whether the graph is acyclic.
    bool acyclic() const @safe pure nothrow @nogc => cycle.length == 0;
}

/**
A topological order of `count` nodes under `edges`, ties broken by the lower
index — so ranking the nodes before numbering them makes the order stable.

On a cycle, `order` is empty and `cycle` holds the shortest cycle among the
nodes Kahn's algorithm could not release, found by breadth-first search from
each in index order (the first shortest wins), rotated to start at its lowest
member ([SPEC §9]).
*/
StableOrder stableTopologicalOrder(size_t count, scope const(IndexEdge)[] edges) @safe pure nothrow
{
    const adjacency = Adjacency(count, edges);
    auto indegree = new uint[count];
    foreach (e; edges)
        indegree[e.to]++;

    auto heap = MinHeap(count);
    foreach (i; 0 .. cast(uint) count)
        if (indegree[i] == 0)
            heap.push(i);

    auto order = new uint[](0);
    order.reserve(count);
    while (!heap.empty)
    {
        const next = heap.pop();
        order ~= next;
        foreach (to; adjacency.successors(next))
            if (--indegree[to] == 0)
                heap.push(to);
    }
    if (order.length == count)
        return StableOrder(order: order);
    return StableOrder(cycle: shortestCycle(adjacency, indegree));
}

/// A chain, a diamond, and a cycle.
@("task.graph.stableTopologicalOrder.tiesAndCycles")
@safe pure nothrow
unittest
{
    // 3 -> 1, 0 and 2 free: the lower index always goes first.
    assert(stableTopologicalOrder(4, [IndexEdge(3, 1)]).order == [0, 2, 3, 1]);
    // Diamond 0 -> {1, 2} -> 3.
    assert(stableTopologicalOrder(4, [IndexEdge(0, 2), IndexEdge(0, 1),
        IndexEdge(2, 3), IndexEdge(1, 3)]).order == [0, 1, 2, 3]);

    // Two cycles: 1 -> 3 -> 2 -> 1 (length 3) and 4 <-> 5 (length 2).
    const cyclic = stableTopologicalOrder(6, [IndexEdge(1, 3), IndexEdge(3, 2),
        IndexEdge(2, 1), IndexEdge(4, 5), IndexEdge(5, 4), IndexEdge(0, 1)]);
    assert(!cyclic.acyclic);
    assert(cyclic.order.length == 0);
    assert(cyclic.cycle == [4, 5], "the shortest cycle wins");

    // A lone three-cycle is reported from its lowest member.
    assert(stableTopologicalOrder(3, [IndexEdge(2, 0), IndexEdge(0, 1),
        IndexEdge(1, 2)]).cycle == [0, 1, 2]);
    // A self-edge is a cycle of one.
    assert(stableTopologicalOrder(2, [IndexEdge(1, 1)]).cycle == [1]);
}

// Successor lists in compressed form: the successors of `i` are
// `targets[start[i] .. start[i + 1]]`, ascending.
private struct Adjacency
{
    uint[] start;
    uint[] targets;

    this(size_t count, scope const(IndexEdge)[] edges) @safe pure nothrow
    {
        start = new uint[count + 1];
        foreach (e; edges)
            start[e.from + 1]++;
        foreach (i; 1 .. count + 1)
            start[i] += start[i - 1];
        targets = new uint[edges.length];
        auto fill = start[0 .. count].dup;
        foreach (e; edges)
            targets[fill[e.from]++] = e.to;
        foreach (i; 0 .. count)
            targets[start[i] .. start[i + 1]].sort();
    }

    const(uint)[] successors(uint i) const return scope @safe pure nothrow @nogc
        => targets[start[i] .. start[i + 1]];
}

// The shortest cycle among the nodes with a nonzero residual indegree.
private uint[] shortestCycle(scope const ref Adjacency adjacency, scope const(uint)[] residual) @safe pure nothrow
{
    const count = residual.length;
    auto parent = new uint[count];
    auto queue = new uint[count];
    uint[] best;
    foreach (source; 0 .. cast(uint) count)
    {
        if (residual[source] == 0)
            continue;
        parent[] = uint.max;
        size_t head, tail;
        queue[tail++] = source;
        uint closing = uint.max; // the node whose edge returns to `source`
        search: while (head < tail)
        {
            const at = queue[head++];
            foreach (next; adjacency.successors(at))
            {
                if (residual[next] == 0)
                    continue;
                if (next == source)
                {
                    closing = at;
                    break search;
                }
                if (parent[next] == uint.max)
                {
                    parent[next] = at;
                    queue[tail++] = next;
                }
            }
        }
        if (closing == uint.max)
            continue;
        uint[] cycle;
        for (uint at = closing; at != source; at = parent[at])
            cycle ~= at;
        cycle ~= source;
        if (best.length == 0 || cycle.length < best.length)
        {
            // Collected backwards; reverse into edge order.
            foreach (i; 0 .. cycle.length / 2)
            {
                const t = cycle[i];
                cycle[i] = cycle[$ - 1 - i];
                cycle[$ - 1 - i] = t;
            }
            best = cycle;
        }
    }
    // Rotate to the lowest member.
    size_t lowest;
    foreach (i, v; best)
        if (v < best[lowest])
            lowest = i;
    return best[lowest .. $] ~ best[0 .. lowest];
}

// A binary min-heap of indices, sized up front.
private struct MinHeap
{
    uint[] items;
    size_t length;

    this(size_t capacity) @safe pure nothrow { items = new uint[capacity]; }

    bool empty() const @safe pure nothrow @nogc => length == 0;

    void push(uint v) @safe pure nothrow @nogc
    {
        size_t i = length++;
        items[i] = v;
        while (i > 0 && items[(i - 1) / 2] > items[i])
        {
            swapAt(i, (i - 1) / 2);
            i = (i - 1) / 2;
        }
    }

    uint pop() @safe pure nothrow @nogc
    {
        const top = items[0];
        items[0] = items[--length];
        size_t i;
        for (;;)
        {
            const l = 2 * i + 1, r = l + 1;
            size_t m = i;
            if (l < length && items[l] < items[m])
                m = l;
            if (r < length && items[r] < items[m])
                m = r;
            if (m == i)
                return top;
            swapAt(i, m);
            i = m;
        }
    }

    private void swapAt(size_t a, size_t b) @safe pure nothrow @nogc
    {
        const t = items[a];
        items[a] = items[b];
        items[b] = t;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Building and validating
// ─────────────────────────────────────────────────────────────────────────────

/// What makes a graph invalid.
@WireCase(CaseStyle.kebabCase)
enum GraphErrorKind
{
    duplicateId,         /// two nodes share an id
    zeroWeight,          /// a node claims no job weight
    unknownPrerequisite, /// an edge's prerequisite names no node
    unknownDependent,    /// an edge's dependent names no node
    selfEdge,            /// an edge from a node to itself
    duplicateEdge,       /// two edges join the same pair
    cycle,               /// the edges form a cycle
}

/**
Why $(LREF TaskGraphBuilder.build) refused. `ids` names the offending nodes:
the duplicated id; the zero-weight node; an edge's `[prerequisite,
dependent]`; or, for a cycle, its members from the lowest, each waiting on the
one before it.
*/
struct GraphError
{
    GraphErrorKind kind; ///
    TaskId[] ids;        ///

    /// `cycle: a -> b -> a`, `duplicate-edge: a -> b`, `duplicate-id: a`.
    void toString(Writer)(ref Writer w) const
    {
        writeEnumMemberName!AnyFormat(w, kind);
        put(w, ": ");
        foreach (i, id; ids)
        {
            if (i)
                put(w, " -> ");
            put(w, id.text);
        }
        if (kind == GraphErrorKind.cycle && ids.length)
        {
            put(w, " -> ");
            put(w, ids[0].text);
        }
    }
}

/// An edge between nodes of a validated graph.
struct GraphEdge
{
    TaskIndex prerequisite;  ///
    TaskIndex dependent;     ///
    EdgeCondition condition; ///
    EdgeReason reason;       ///
}

/// Collects nodes and edges in any order; $(LREF build) validates them.
struct TaskGraphBuilder
{
    private TaskNode[] nodes;
    private TaskEdge[] edges;

    /// Adds a node.
    void add(TaskNode node) @safe pure nothrow { nodes ~= node; }

    /// Adds an edge.
    void add(TaskEdge edge) @safe pure nothrow { edges ~= edge; }

    /**
    Validates and freezes the graph. Checks run in a fixed order — duplicate
    ids, zero weights, unknown endpoints, self-edges, duplicate edges, cycles
    — and each reports its lowest offender, so the same input always yields
    the same error.
    */
    PlanExpected!(TaskGraph, GraphError) build() @safe pure nothrow
    {
        // Rank by id, for lookups and the duplicate check.
        auto byId = new uint[nodes.length];
        foreach (i, ref _; byId)
            _ = cast(uint) i;
        byId.sort!((a, b) => nodes[a].id < nodes[b].id);
        foreach (i; 1 .. byId.length)
            if (nodes[byId[i]].id == nodes[byId[i - 1]].id)
                return fail(GraphErrorKind.duplicateId, [nodes[byId[i]].id]);

        // Presentation order: key, then id.
        auto perm = byId.dup;
        perm.sort!((a, b) => nodes[a].order < nodes[b].order
            || (!(nodes[b].order < nodes[a].order) && nodes[a].id < nodes[b].id));

        TaskGraph graph;
        graph.nodes_.reserve(nodes.length);
        auto rank = new uint[nodes.length]; // insertion index -> TaskIndex
        foreach (position, inserted; perm)
        {
            graph.nodes_ ~= nodes[inserted];
            rank[inserted] = cast(uint) position;
        }
        foreach (ref node; graph.nodes_)
            if (node.resources.jobsWeight == 0)
                return fail(GraphErrorKind.zeroWeight, [node.id]);
        graph.byId_ = new TaskIndex[nodes.length];
        foreach (i, inserted; byId)
            graph.byId_[i] = TaskIndex(rank[inserted]);

        // Resolve edges in a canonical order so the first offender is stable.
        auto edgeOrder = new uint[edges.length];
        foreach (i, ref _; edgeOrder)
            _ = cast(uint) i;
        edgeOrder.sort!((a, b) => edges[a].dependent < edges[b].dependent
            || (edges[a].dependent == edges[b].dependent
                && edges[a].prerequisite < edges[b].prerequisite));
        foreach (e; edgeOrder)
        {
            const edge = edges[e];
            const from = graph.indexOf(edge.prerequisite);
            const to = graph.indexOf(edge.dependent);
            if (!from.valid)
                return fail(GraphErrorKind.unknownPrerequisite, [edge.prerequisite, edge.dependent]);
            if (!to.valid)
                return fail(GraphErrorKind.unknownDependent, [edge.prerequisite, edge.dependent]);
            if (from == to)
                return fail(GraphErrorKind.selfEdge, [edge.prerequisite, edge.dependent]);
            graph.edges_ ~= GraphEdge(from, to, edge.condition, edge.reason);
        }
        // Incoming edges contiguous per dependent, by prerequisite.
        graph.edges_.sort!((a, b) => a.dependent < b.dependent
            || (a.dependent == b.dependent && a.prerequisite < b.prerequisite));
        foreach (i; 1 .. graph.edges_.length)
        {
            const a = graph.edges_[i - 1], b = graph.edges_[i];
            if (a.dependent == b.dependent && a.prerequisite == b.prerequisite)
                return fail(GraphErrorKind.duplicateEdge,
                    [graph.nodes_[b.prerequisite.value].id, graph.nodes_[b.dependent.value].id]);
        }

        graph.inStart_ = new uint[graph.nodes_.length + 1];
        foreach (e; graph.edges_)
            graph.inStart_[e.dependent.value + 1]++;
        foreach (i; 1 .. graph.inStart_.length)
            graph.inStart_[i] += graph.inStart_[i - 1];

        auto indexEdges = new IndexEdge[graph.edges_.length];
        foreach (i, e; graph.edges_)
            indexEdges[i] = IndexEdge(e.prerequisite.value, e.dependent.value);
        auto sorted = stableTopologicalOrder(graph.nodes_.length, indexEdges);
        if (!sorted.acyclic)
        {
            auto ids = new TaskId[sorted.cycle.length];
            foreach (i, v; sorted.cycle)
                ids[i] = graph.nodes_[v].id;
            return fail(GraphErrorKind.cycle, ids);
        }
        graph.topo_ = new TaskIndex[sorted.order.length];
        foreach (i, v; sorted.order)
            graph.topo_[i] = TaskIndex(v);

        // Outgoing edges, by prerequisite then dependent.
        graph.outgoing_ = new uint[graph.edges_.length];
        foreach (i, ref _; graph.outgoing_)
            _ = cast(uint) i;
        graph.outgoing_.sort!((a, b) => graph.edges_[a].prerequisite < graph.edges_[b].prerequisite
            || (graph.edges_[a].prerequisite == graph.edges_[b].prerequisite
                && graph.edges_[a].dependent < graph.edges_[b].dependent));
        graph.outStart_ = new uint[graph.nodes_.length + 1];
        foreach (e; graph.edges_)
            graph.outStart_[e.prerequisite.value + 1]++;
        foreach (i; 1 .. graph.outStart_.length)
            graph.outStart_[i] += graph.outStart_[i - 1];

        import core.lifetime : move;

        return planOk!GraphError(move(graph));
    }

    private static PlanExpected!(TaskGraph, GraphError) fail(GraphErrorKind kind, TaskId[] ids) @safe pure nothrow
        => planErr!TaskGraph(GraphError(kind, ids));
}

/**
A validated, acyclic task graph. Nodes are in presentation order; an edge
list per node is sorted by the other end's index.
*/
struct TaskGraph
{
    private TaskNode[] nodes_;
    private GraphEdge[] edges_;  // by dependent, then prerequisite
    private uint[] inStart_;     // incoming of i: edges_[inStart_[i] .. inStart_[i + 1]]
    private uint[] outgoing_;    // edge indices by prerequisite, then dependent
    private uint[] outStart_;    // outgoing of i: outgoing_[outStart_[i] .. outStart_[i + 1]]
    private TaskIndex[] byId_;   // node indices sorted by id
    private TaskIndex[] topo_;   // stable topological order

    /// The nodes, in presentation order.
    const(TaskNode)[] nodes() const return @safe pure nothrow @nogc => nodes_;

    /// The edges, by dependent then prerequisite.
    const(GraphEdge)[] edges() const return @safe pure nothrow @nogc => edges_;

    /// The node at `index`.
    ref const(TaskNode) opIndex(TaskIndex index) const return @safe pure nothrow @nogc
        => nodes_[index.value];

    /// The node with `id`, or an invalid index. A binary search; no hashing.
    TaskIndex indexOf(const TaskId id) const @safe pure nothrow @nogc
    {
        size_t lo, hi = byId_.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            const candidate = nodes_[byId_[mid].value].id;
            if (candidate == id)
                return byId_[mid];
            if (candidate < id)
                lo = mid + 1;
            else
                hi = mid;
        }
        return TaskIndex.init;
    }

    /// The edges `index` waits on, by prerequisite.
    const(GraphEdge)[] incoming(TaskIndex index) const return @safe pure nothrow @nogc
        => edges_[inStart_[index.value] .. inStart_[index.value + 1]];

    /// The edges waiting on `index`, by dependent.
    OutgoingEdges outgoing(TaskIndex index) const return @safe pure nothrow @nogc
        => OutgoingEdges(edges_, outgoing_[outStart_[index.value] .. outStart_[index.value + 1]]);

    /// Every node, prerequisites first, ties in presentation order.
    const(TaskIndex)[] topologicalOrder() const return @safe pure nothrow @nogc => topo_;
}

/// The edges leaving one node: a random-access range of
/// $(LREF GraphEdge), by dependent.
struct OutgoingEdges
{
    private const(GraphEdge)[] edges;
    private const(uint)[] indices;

    bool empty() const scope @safe pure nothrow @nogc => indices.length == 0;
    size_t length() const scope @safe pure nothrow @nogc => indices.length;
    GraphEdge front() const scope @safe pure nothrow @nogc => edges[indices[0]];
    GraphEdge opIndex(size_t i) const scope @safe pure nothrow @nogc => edges[indices[i]];
    void popFront() scope @safe pure nothrow @nogc { indices = indices[1 .. $]; }
    OutgoingEdges save() const @safe pure nothrow @nogc => OutgoingEdges(edges, indices);
}

version (unittest)
{
    import std.algorithm.iteration : map;
    import std.array : array;

    private TaskId id(string text) @safe pure nothrow
    {
        const(char)[][] segments;
        size_t start;
        foreach (i, c; text)
            if (c == ':')
            {
                segments ~= text[start .. i];
                start = i + 1;
            }
        segments ~= text[start .. $];
        return taskId(segments).value;
    }

    private TaskNode node(string text, uint phase = 0, uint ordinal = 0) @safe pure nothrow
    {
        import task.action : InertAction;

        return TaskNode(id(text), TaskKind.test, text, PresentationKey(phase, null, 0, ordinal),
            defaultClaim(TaskKind.test), TaskAction(InertAction(text)));
    }

    private TaskEdge edge(string from, string to,
        EdgeCondition condition = EdgeCondition.onSuccess) @safe pure nothrow
        => TaskEdge(id(from), id(to), condition, EdgeReason.packageDependency);

    private string[] ids(const ref TaskGraph g, scope const(TaskIndex)[] indices) @safe pure nothrow
        => indices.map!(i => g[i].id.text).array;

    private string errorText(const GraphError e) @safe
    {
        import std.conv : text;

        return text(e);
    }
}

@("task.graph.build.rejectsDuplicatesAndUnknownEdges")
@safe
unittest
{
    TaskGraphBuilder dup;
    dup.add(node("a"));
    dup.add(node("b"));
    dup.add(node("a"));
    assert(errorText(dup.build().error) == "duplicate-id: a");

    TaskGraphBuilder unknown;
    unknown.add(node("a"));
    unknown.add(edge("missing", "a"));
    assert(errorText(unknown.build().error) == "unknown-prerequisite: missing -> a");

    TaskGraphBuilder unknownDependent;
    unknownDependent.add(node("a"));
    unknownDependent.add(edge("a", "gone"));
    assert(unknownDependent.build().error.kind == GraphErrorKind.unknownDependent);

    TaskGraphBuilder self;
    self.add(node("a"));
    self.add(edge("a", "a"));
    assert(errorText(self.build().error) == "self-edge: a -> a");

    TaskGraphBuilder twice;
    twice.add(node("a"));
    twice.add(node("b"));
    twice.add(edge("a", "b"));
    twice.add(edge("a", "b", EdgeCondition.always));
    assert(errorText(twice.build().error) == "duplicate-edge: a -> b");

    TaskGraphBuilder weightless;
    auto n = node("a");
    n.resources.jobsWeight = 0;
    weightless.add(n);
    assert(errorText(weightless.build().error) == "zero-weight: a");
}

@("task.graph.build.reportsTheShortestCycleFromItsLowestMember")
@safe
unittest
{
    TaskGraphBuilder b;
    foreach (name; ["e", "d", "c", "b", "a", "z"])
        b.add(node(name));
    // c -> e -> d -> c, and a <-> b; z hangs off the long cycle.
    b.add(edge("c", "e"));
    b.add(edge("e", "d"));
    b.add(edge("d", "c"));
    b.add(edge("b", "a"));
    b.add(edge("a", "b"));
    b.add(edge("d", "z"));
    assert(errorText(b.build().error) == "cycle: a -> b -> a");

    TaskGraphBuilder three;
    foreach (name; ["e", "d", "c"])
        three.add(node(name));
    three.add(edge("c", "e"));
    three.add(edge("e", "d"));
    three.add(edge("d", "c"));
    // Each member waits on the one before it: e waits on c.
    assert(errorText(three.build().error) == "cycle: c -> e -> d -> c");
}

@("task.graph.build.orderIsIndependentOfInsertionOrder")
@safe pure nothrow
unittest
{
    static TaskGraph make(scope const(size_t)[] permutation) @safe pure nothrow
    {
        auto nodes = [node("t:b", 1), node("t:a", 1), node("t:c", 0), node("t:d", 1, 1),
            node("t:e", 2)];
        auto edges = [edge("t:c", "t:d"), edge("t:a", "t:e"), edge("t:b", "t:e"),
            edge("t:d", "t:e", EdgeCondition.onCompletion)];
        TaskGraphBuilder b;
        foreach (i; permutation)
            b.add(nodes[i]);
        foreach_reverse (i; permutation)
            if (i < edges.length)
                b.add(edges[i]);
        return b.build().value;
    }

    const g = make([0, 1, 2, 3, 4]);
    // Presentation: phase, owner, work, ordinal, then id.
    assert(ids(g, g.topologicalOrder) == ["t:c", "t:a", "t:b", "t:d", "t:e"]);
    assert(g.nodes.map!(n => n.id.text).array == ["t:c", "t:a", "t:b", "t:d", "t:e"]);

    // An associative array's iteration order is one more permutation: feed
    // nodes in whatever order a keyed table yields them.
    size_t[string] table = ["t:b": 0, "t:a": 1, "t:c": 2, "t:d": 3, "t:e": 4];
    size_t[] fromTable;
    foreach (_, i; table)
        fromTable ~= i;

    size_t[] reversed = [4, 3, 2, 1, 0], shuffled = [2, 0, 4, 1, 3];
    size_t[][] permutations = [reversed, shuffled, fromTable];
    foreach (permutation; permutations)
    {
        const h = make(permutation);
        assert(h.nodes.map!(n => n.id.text).array == g.nodes.map!(n => n.id.text).array);
        assert(h.edges == g.edges);
        assert(h.topologicalOrder == g.topologicalOrder);
    }

    const e = g.indexOf(id("t:e"));
    assert(g.incoming(e).map!(x => g[x.prerequisite].id.text).array == ["t:a", "t:b", "t:d"]);
    assert(g.outgoing(g.indexOf(id("t:c"))).map!(x => g[x.dependent].id.text).array == ["t:d"]);
    assert(!g.indexOf(id("t:zz")).valid);
}

@("task.graph.build.topologicalOrderRespectsEdgesOverPresentation")
@safe pure nothrow
unittest
{
    TaskGraphBuilder b;
    b.add(node("a"));
    b.add(node("b"));
    b.add(node("c"));
    b.add(edge("c", "a"));
    const g = b.build().value;
    assert(ids(g, g.topologicalOrder) == ["b", "c", "a"]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Edge conditions and blocked propagation
// ─────────────────────────────────────────────────────────────────────────────

/// An edge, given its prerequisite's terminal outcome.
@WireCase(CaseStyle.kebabCase)
enum EdgeState
{
    satisfied,  /// the condition holds
    impossible, /// the condition can no longer hold
}

/**
Resolves an edge whose prerequisite reached `prerequisite`:

$(TABLE
    $(TR $(TH condition) $(TH satisfied by))
    $(TR $(TD `onSuccess`) $(TD succeeded, degraded, skipped))
    $(TR $(TD `onFailure`) $(TD failed))
    $(TR $(TD `onCompletion`) $(TD every outcome but cancelled))
    $(TR $(TD `always`) $(TD every outcome))
)

A skipped prerequisite satisfies `onSuccess`: a skip is an eligibility rule,
not a broken contract, and dub still compiles an unselected dependency.
*/
EdgeState resolveEdge(EdgeCondition condition, OutcomeKind prerequisite) @safe pure nothrow @nogc
{
    final switch (condition)
    {
        case EdgeCondition.onSuccess:
            return prerequisite == OutcomeKind.succeeded || prerequisite == OutcomeKind.degraded
                || prerequisite == OutcomeKind.skipped ? EdgeState.satisfied : EdgeState.impossible;
        case EdgeCondition.onFailure:
            return prerequisite == OutcomeKind.failed ? EdgeState.satisfied : EdgeState.impossible;
        case EdgeCondition.onCompletion:
            return prerequisite == OutcomeKind.cancelled ? EdgeState.impossible : EdgeState.satisfied;
        case EdgeCondition.always:
            return EdgeState.satisfied;
    }
}

///
@("task.graph.resolveEdge.conditions")
@safe pure nothrow @nogc
unittest
{
    with (EdgeCondition) with (OutcomeKind) with (EdgeState)
    {
        assert(resolveEdge(onSuccess, succeeded) == satisfied);
        assert(resolveEdge(onSuccess, degraded) == satisfied);
        assert(resolveEdge(onSuccess, skipped) == satisfied);
        assert(resolveEdge(onSuccess, failed) == impossible);
        assert(resolveEdge(onSuccess, blocked) == impossible);
        assert(resolveEdge(onFailure, failed) == satisfied);
        assert(resolveEdge(onFailure, succeeded) == impossible);
        assert(resolveEdge(onFailure, cancelled) == impossible);
        assert(resolveEdge(onCompletion, failed) == satisfied);
        assert(resolveEdge(onCompletion, blocked) == satisfied);
        assert(resolveEdge(onCompletion, cancelled) == impossible);
        assert(resolveEdge(always, cancelled) == satisfied);
    }
}

/// A task's outcome so far: null until terminal.
alias OutcomeSlot = Nullable!TaskOutcome;

/// Where a not-yet-terminal task stands.
@WireCase(CaseStyle.kebabCase)
enum ReadinessKind
{
    waiting, /// some prerequisite is not terminal
    ready,   /// every edge is satisfied
    blocked, /// every prerequisite is terminal and some edge is impossible
}

/// $(LREF readiness)'s answer; `blocked` is meaningful only for
/// `ReadinessKind.blocked`.
struct Readiness
{
    ReadinessKind kind; ///
    Blocked blocked;    ///
}

/**
Where `task` stands given `outcomes` (one slot per node, by index).

A task is decided only once $(I every) prerequisite is terminal, so its
outcome never depends on which prerequisite finished first. A blocked task's
`cause` is its lowest-index impossible prerequisite that descends from a
failure, else its lowest-index impossible prerequisite; `root` and
`fromFailure` follow the cause's own chain.
*/
Readiness readiness(const ref TaskGraph graph, TaskIndex task, scope const(OutcomeSlot)[] outcomes)
    @safe pure nothrow @nogc
{
    TaskIndex firstImpossible, firstFromFailure;
    foreach (edge; graph.incoming(task))
    {
        const slot = outcomes[edge.prerequisite.value];
        if (slot.isNull)
            return Readiness(ReadinessKind.waiting);
        if (resolveEdge(edge.condition, kindOf(slot.get)) == EdgeState.satisfied)
            continue;
        if (!firstImpossible.valid)
            firstImpossible = edge.prerequisite;
        if (!firstFromFailure.valid && descendsFromFailure(slot.get))
            firstFromFailure = edge.prerequisite;
    }
    if (!firstImpossible.valid)
        return Readiness(ReadinessKind.ready);
    const cause = firstFromFailure.valid ? firstFromFailure : firstImpossible;
    return Readiness(ReadinessKind.blocked, blockedBy(cause, outcomes[cause.value].get));
}

/**
Marks every task that can no longer run as $(REF Blocked, task,model), in
topological order so a block cascades through a chain in one pass. Tasks that
are ready or waiting keep a null slot. Returns how many tasks it blocked.
*/
size_t propagateBlocked(const ref TaskGraph graph, scope OutcomeSlot[] outcomes) @safe pure nothrow @nogc
in (outcomes.length == graph.nodes.length)
{
    size_t blocked;
    foreach (task; graph.topologicalOrder)
    {
        if (!outcomes[task.value].isNull)
            continue;
        const r = readiness(graph, task, outcomes);
        if (r.kind == ReadinessKind.blocked)
        {
            outcomes[task.value] = TaskOutcome(r.blocked);
            blocked++;
        }
    }
    return blocked;
}

// Whether a prerequisite's outcome makes its dependents' block a failure.
private bool descendsFromFailure(const TaskOutcome outcome) @safe pure nothrow @nogc
    => failsCommand(outcome);

// The block a dependent takes from an impossible prerequisite `cause`.
private Blocked blockedBy(TaskIndex cause, const TaskOutcome outcome) @safe pure nothrow @nogc
{
    import std.sumtype : match;

    return outcome.match!(
        (const Failed _) => Blocked(BlockReason.prerequisiteFailed, cause, cause, true),
        (const Cancelled _) => Blocked(BlockReason.prerequisiteCancelled, cause, cause, false),
        (const Blocked b) => Blocked(BlockReason.prerequisiteBlocked, cause, b.root, b.fromFailure),
        _ => Blocked(BlockReason.conditionUnmet, cause, cause, false),
    );
}

@("task.graph.propagateBlocked.cascadesAndKeepsTheRoot")
@safe pure nothrow
unittest
{
    // a -> b -> c (onSuccess); a -> fallback (onFailure);
    // b -> summary, c -> summary (onCompletion); summary -> cleanup (always).
    TaskGraphBuilder builder;
    foreach (name; ["a", "b", "c", "fallback", "summary", "cleanup"])
        builder.add(node(name));
    builder.add(edge("a", "b"));
    builder.add(edge("b", "c"));
    builder.add(edge("a", "fallback", EdgeCondition.onFailure));
    builder.add(edge("b", "summary", EdgeCondition.onCompletion));
    builder.add(edge("c", "summary", EdgeCondition.onCompletion));
    builder.add(edge("summary", "cleanup", EdgeCondition.always));
    const g = builder.build().value;
    TaskIndex at(string name) => g.indexOf(id(name));

    auto outcomes = new OutcomeSlot[g.nodes.length];
    assert(readiness(g, at("b"), outcomes).kind == ReadinessKind.waiting);

    // a fails: b and c block from it, the fallback becomes ready, the
    // summary (onCompletion of blocked tasks) becomes ready.
    outcomes[at("a").value] = TaskOutcome(Failed(FailureReason.exitStatus, 1));
    assert(propagateBlocked(g, outcomes) == 2);
    const b = outcomes[at("b").value].get;
    const c = outcomes[at("c").value].get;
    assert(b == TaskOutcome(Blocked(BlockReason.prerequisiteFailed, at("a"), at("a"), true)));
    assert(c == TaskOutcome(Blocked(BlockReason.prerequisiteBlocked, at("b"), at("a"), true)));
    assert(failsCommand(c));
    assert(readiness(g, at("fallback"), outcomes).kind == ReadinessKind.ready);
    assert(readiness(g, at("summary"), outcomes).kind == ReadinessKind.ready);
    assert(readiness(g, at("cleanup"), outcomes).kind == ReadinessKind.waiting);

    // A cancelled summary blocks nothing that runs `always`.
    outcomes[at("summary").value] = TaskOutcome(Cancelled(CancelReason.notAdmitted));
    assert(propagateBlocked(g, outcomes) == 0);
    assert(readiness(g, at("cleanup"), outcomes).kind == ReadinessKind.ready);
}

@("task.graph.propagateBlocked.successBlocksTheFallbackWithoutFailing")
@safe pure nothrow
unittest
{
    TaskGraphBuilder builder;
    builder.add(node("coverage"));
    builder.add(node("plain"));
    builder.add(edge("coverage", "plain", EdgeCondition.onFailure));
    const g = builder.build().value;

    auto outcomes = new OutcomeSlot[2];
    outcomes[g.indexOf(id("coverage")).value] = TaskOutcome(Succeeded());
    assert(propagateBlocked(g, outcomes) == 1);
    const plain = outcomes[g.indexOf(id("plain")).value].get;
    assert(kindOf(plain) == OutcomeKind.blocked);
    assert(!failsCommand(plain), "an unneeded fallback is no failure");
}

@("task.graph.readiness.preferAFailureCauseRegardlessOfCompletionOrder")
@safe pure nothrow
unittest
{
    TaskGraphBuilder builder;
    foreach (name; ["a", "b", "c"])
        builder.add(node(name));
    builder.add(edge("a", "c"));
    builder.add(edge("b", "c"));
    const g = builder.build().value;
    const a = g.indexOf(id("a")), b = g.indexOf(id("b")), c = g.indexOf(id("c"));

    // Either completion order leaves c waiting until both are terminal…
    auto outcomes = new OutcomeSlot[3];
    outcomes[a.value] = TaskOutcome(Cancelled(CancelReason.notAdmitted));
    assert(readiness(g, c, outcomes).kind == ReadinessKind.waiting);
    outcomes[b.value] = TaskOutcome(Failed(FailureReason.signal, 9));
    // …and then the failure, not the lower-index cancellation, is the cause.
    const r = readiness(g, c, outcomes);
    assert(r.kind == ReadinessKind.blocked);
    assert(r.blocked == Blocked(BlockReason.prerequisiteFailed, b, b, true));
}

// ─────────────────────────────────────────────────────────────────────────────
// Dry-run projection
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes the dry-run plan of `graph` ([SPEC §12]): nodes in presentation order
with their kind, claim, and redacted action summary; edges with condition and
reason; counts by kind; and the total weighted capacity.

---
    nodes (2):
        build:sparkles.base kind=build weight=2: inert
        build:sparkles.ui kind=build weight=2 exclusive=coverage-publish: inert
    edges (1):
        build:sparkles.base -> build:sparkles.ui (on-success, package-dependency)
    kinds: build=2
    capacity: 8
---
*/
void writePlan(Writer)(ref Writer w, const ref TaskGraph graph, uint capacity)
{
    put(w, "nodes (");
    writeValue(w, graph.nodes.length);
    put(w, "):\n");
    foreach (ref n; graph.nodes)
    {
        put(w, "  ");
        put(w, n.id.text);
        put(w, " kind=");
        writeEnumMemberName!AnyFormat(w, n.kind);
        put(w, " weight=");
        writeValue(w, n.resources.jobsWeight);
        if (n.resources.memoryHintBytes)
        {
            put(w, " memory=");
            writeValue(w, n.resources.memoryHintBytes);
        }
        foreach (i, key; n.resources.exclusiveKeys)
        {
            put(w, i ? "," : " exclusive=");
            put(w, key);
        }
        if (n.failurePolicy != FailurePolicy.authoritative)
        {
            put(w, " failure=");
            writeEnumMemberName!AnyFormat(w, n.failurePolicy);
        }
        put(w, ": ");
        writeActionSummary(w, n.action);
        put(w, '\n');
    }

    put(w, "edges (");
    writeValue(w, graph.edges.length);
    put(w, "):\n");
    foreach (index; 0 .. cast(uint) graph.nodes.length)
        foreach (e; graph.outgoing(TaskIndex(index)))
        {
            put(w, "  ");
            put(w, graph[e.prerequisite].id.text);
            put(w, " -> ");
            put(w, graph[e.dependent].id.text);
            put(w, " (");
            writeEnumMemberName!AnyFormat(w, e.condition);
            put(w, ", ");
            writeEnumMemberName!AnyFormat(w, e.reason);
            put(w, ")\n");
        }

    put(w, "kinds:");
    size_t[TaskKind.max + 1] counts;
    foreach (ref n; graph.nodes)
        counts[n.kind]++;
    foreach (kind, count; counts)
    {
        if (!count)
            continue;
        put(w, ' ');
        writeEnumMemberName!AnyFormat(w, cast(TaskKind) kind);
        put(w, '=');
        writeValue(w, count);
    }
    put(w, "\ncapacity: ");
    writeValue(w, capacity);
    put(w, '\n');
}

@("task.graph.writePlan.dryRun")
@safe pure nothrow
unittest
{
    import sparkles.base.buffer : checkWriter;
    import task.action : EnvEntry, InProcessAction, ProcessAction;

    TaskGraphBuilder builder;
    builder.add(TaskNode(id("test:sparkles.ui:unittest"), TaskKind.test, "ui",
        PresentationKey(1, "sparkles:ui"), ResourceClaim(4, 1024, ["coverage-publish"]),
        TaskAction(ProcessAction(["dub", "test", ":ui"],
            [EnvEntry("TOKEN", "secret", redacted: true)])),
        FailurePolicy.provisional));
    builder.add(TaskNode(id("test:sparkles.base:unittest"), TaskKind.test, "base",
        PresentationKey(1, "sparkles:base"), defaultClaim(TaskKind.test),
        TaskAction(ProcessAction(["dub", "test", ":base"]))));
    builder.add(TaskNode(id("summary"), TaskKind.report, "summary", PresentationKey(2),
        defaultClaim(TaskKind.report), TaskAction(InProcessAction("report:summary"))));
    builder.add(TaskEdge(id("test:sparkles.base:unittest"), id("test:sparkles.ui:unittest"),
        EdgeCondition.onSuccess, EdgeReason.packageDependency));
    builder.add(TaskEdge(id("test:sparkles.ui:unittest"), id("summary"),
        EdgeCondition.onCompletion, EdgeReason.summary));
    builder.add(TaskEdge(id("test:sparkles.base:unittest"), id("summary"),
        EdgeCondition.onCompletion, EdgeReason.summary));
    const g = builder.build().value;

    checkWriter!((ref b) => writePlan(b, g, 8))(
        "nodes (3):\n"
        ~ "  test:sparkles.base:unittest kind=test weight=2: run dub test :base\n"
        ~ "  test:sparkles.ui:unittest kind=test weight=4 memory=1024 exclusive=coverage-publish"
        ~ " failure=provisional: run TOKEN=<redacted> dub test :ui\n"
        ~ "  summary kind=report weight=1: call report:summary()\n"
        ~ "edges (3):\n"
        ~ "  test:sparkles.base:unittest -> test:sparkles.ui:unittest (on-success, package-dependency)\n"
        ~ "  test:sparkles.base:unittest -> summary (on-completion, summary)\n"
        ~ "  test:sparkles.ui:unittest -> summary (on-completion, summary)\n"
        ~ "kinds: test=2 report=1\n"
        ~ "capacity: 8\n");
}
