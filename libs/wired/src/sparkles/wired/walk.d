/**
Format-neutral navigation over a reified wire schema.

Codecs specialize their leaf I/O and value construction while sharing this
cursor for node dispatch, child traversal, policy lookup, and recursive
reference resolution.
*/
module sparkles.wired.walk;

import sparkles.wired.schema : NodeKind, wireSchemaOf;
import sparkles.wired.policy : FieldPolicy;

/// Compile-time cursor over the schema of one `(format, root type)` pair.
template WireWalk(Format, Root)
{
    enum schema = wireSchemaOf!(Format, Root);

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
