/**
Format-neutral navigation over a reified wire schema.

Codecs specialize their leaf I/O and value construction while sharing this
cursor for node dispatch, child traversal, policy lookup, and recursive
reference resolution.
*/
module sparkles.wired.walk;

import sparkles.wired.schema : NodeKind, wireSchemaOf;
import sparkles.wired.policy : FieldPolicy;

/// Marker selecting the zero-sink, fail-fast specialization of a codec walk.
package struct FailFast
{
}

/// Shared output-range protocol and first-error state for accumulating walks.
package struct WireErrors(Sink, Error)
{
    static if (is(Sink == FailFast))
        enum size_t count = 0;
    else
    {
        Sink* sink;
        size_t count;
        Error first;
    }

    void record(Error error)
    {
        static if (!is(Sink == FailFast))
        {
            import std.range.primitives : put;

            if (count++ == 0)
                first = error;
            put(*sink, error);
        }
    }
}

/** Fixed-capacity error output range. It retains the first `capacity`
errors; any further error is dropped and recorded once by a final
`Error.sinkOverflow()` marker, held in a slot of its own so no retained error
is overwritten. */
struct FixedWireErrors(Error, size_t capacity)
if (capacity > 0)
{
    private Error[capacity + 1] storage;
    private size_t used;

    /// Records one failure, or the overflow marker once capacity is reached.
    void put(Error error)
    {
        if (used < capacity)
            storage[used++] = error;
        else if (used == capacity)
            storage[used++] = Error.sinkOverflow();
    }

    /// Number of retained entries, including the overflow marker when present.
    size_t length() const @safe pure nothrow @nogc => used;

    /// Whether at least one error was dropped.
    bool overflowed() const @safe pure nothrow @nogc => used > capacity;

    /// Borrowed diagnostic entries in reporting order. Narrow trust: slicing
    /// the inline storage of a `scope` `this`, bound by `return` to the sink.
    const(Error)[] opSlice() const scope return @safe pure nothrow @nogc
        => (() @trusted => storage[0 .. used])();
}

/// A full bounded sink keeps every retained error and appends one marker.
@("wired.walk.fixedErrors.overflow")
@safe pure nothrow @nogc unittest
{
    static struct Error
    {
        int code;
        static Error sinkOverflow() @safe pure nothrow @nogc => Error(-1);
    }
    FixedWireErrors!(Error, 2) sink;
    sink.put(Error(1));
    sink.put(Error(2));
    assert(sink.length == 2 && !sink.overflowed);
    sink.put(Error(3));
    sink.put(Error(4));
    assert(sink.length == 3 && sink.overflowed);
    assert(sink[][0].code == 1 && sink[][1].code == 2 && sink[][2].code == -1);

    FixedWireErrors!(Error, 1) one;
    one.put(Error(7));
    one.put(Error(8));
    assert(one[][0].code == 7 && one[][1].code == -1);
}

/// Compile-time cursor over the schema of one `(format, root type)` pair.
template WireWalk(Format, Root, alias schemaData = wireSchemaOf!(Format, Root))
{
    enum schema = schemaData;

    /// Resolves a recursion edge to the node it names.
    template resolvedIndex(size_t nodeIndex)
    {
        enum node = schema.nodes[nodeIndex];
        enum size_t resolvedIndex = node.kind == NodeKind.reference
            ? node.referenceIndex : nodeIndex;
    }

    /// The resolved node at `nodeIndex`.
    template node(size_t nodeIndex)
    {
        enum node = schema.nodes[resolvedIndex!nodeIndex];
    }

    /// Child `ordinal` of the resolved node at `nodeIndex`.
    template child(size_t nodeIndex, size_t ordinal)
    {
        enum current = node!nodeIndex;
        static assert(ordinal < current.edgeCount, "wired: schema child out of range");
        enum size_t child = schema.edges[current.firstEdge + ordinal];
    }

    /// Aggregate child policies at this exact schema site.
    template childPolicies(size_t nodeIndex)
    {
        enum current = node!nodeIndex;
        static assert(current.kind == NodeKind.aggregate,
            "wired: childPolicies requires an aggregate node");
        static immutable FieldPolicy[] childPolicies = () {
            FieldPolicy[] result;
            foreach (ordinal; 0 .. current.edgeCount)
                result ~= schema.nodes[
                    schema.edges[current.firstEdge + ordinal]].policy.field;
            return result;
        }();
    }
}
