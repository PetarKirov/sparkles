/**
Merging the diagnostics of a module's two analyses (spec `TGT9`).

A `@compute(CompileFor.hostAndDevice)` module is compiled twice for real —
once for the host, once for the GPU — under different version identifiers,
runtimes and rules, and an error can exist on either side alone. It is
analyzed twice as well, and one payload has to carry both: the $(I primary)
analysis (the host, whose hovers the reader explores) keeps its nodes, and
the $(I other) contributes its error nodes.

An error both sides report is one fact about the source and stays as it is.
An error only one side reports is a fact about that side, so its text gains
the side's tag (`[host] …`, `[device] …`) — without it, a reader would chase a
host error that the device build does not have, or the other way around.
*/
module sparkles.twoslash_d.merge;

import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn;

/**
Folds `other`'s error nodes into `primary` and tags each side's own errors.

Returns, for each node of the merged `primary`, its index in the
$(I original) `primary.nodes` — `size_t.max` for a node that came from
`other`. A resident oracle whose analysis still answers by the original
index (`twoslash-extract --serve`) translates through it.

The two payloads must describe the same display source; when they do not
(the sides disagree about the notation, which should not happen), `primary`
is left alone and only the identity mapping is returned — a merge that
misplaces spans is worse than a missing tag.
*/
size_t[] mergeSideDiagnostics(ref TwoslashReturn primary, string primaryTag,
    in TwoslashReturn other, string otherTag) @safe pure
{
    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.range : iota, zip;

    auto origin = iota(primary.nodes.length).array;
    if (primary.code != other.code)
        return origin;

    static bool sameError(in Node a, in Node b) @safe pure nothrow @nogc
        => a.start == b.start && a.length == b.length && a.text == b.text;

    const(Node)[] otherErrors;
    foreach (ref n; other.nodes)
        if (n.type == NodeType.error)
            otherErrors ~= n;

    const primaryErrors = primary.nodes.dup;
    foreach (ref n; primary.nodes)
        if (n.type == NodeType.error && !otherErrors.canFind!sameError(n))
            n.text = "[" ~ primaryTag ~ "] " ~ n.text;

    foreach (ref n; otherErrors)
        if (!primaryErrors.canFind!(p => p.type == NodeType.error && sameError(p, n)))
        {
            // An error node's own fields — the rest stay at their defaults.
            primary.nodes ~= Node(type: n.type, start: n.start, length: n.length,
                line: n.line, character: n.character,
                text: "[" ~ otherTag ~ "] " ~ n.text,
                level: n.level, code: n.code, id: n.id);
            origin ~= size_t.max;
        }

    // The emitter's order (`start`, then kind), so renderers that walk the
    // list once see the merged nodes where they belong. A stable sort keeps
    // equal-key nodes in production order.
    auto pairs = zip(primary.nodes, origin);
    pairs.sort!((a, b) => a[0].start != b[0].start
        ? a[0].start < b[0].start : a[0].type < b[0].type, SwapStrategy.stable);
    return origin;
}

@("twoslash_d.merge.mergeSideDiagnostics")
@safe pure unittest
{
    auto host = TwoslashReturn(code: "abcdefghij", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, text: "int a"),
        Node(type: NodeType.error, start: 2, length: 1, text: "both sides"),
        Node(type: NodeType.error, start: 6, length: 1, text: "host only"),
    ]);
    const device = TwoslashReturn(code: "abcdefghij", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, text: "ignored"),
        Node(type: NodeType.error, start: 2, length: 1, text: "both sides"),
        Node(type: NodeType.error, start: 4, length: 2, text: "device only"),
    ]);

    const origin = mergeSideDiagnostics(host, "host", device, "device");

    assert(host.nodes.length == 4);
    assert(host.nodes[0].text == "int a");
    assert(host.nodes[1].text == "both sides");
    assert(host.nodes[2].text == "[device] device only");
    assert(host.nodes[2].start == 4);
    assert(host.nodes[3].text == "[host] host only");
    assert(origin == [0, 1, size_t.max, 2]);
}

@("twoslash_d.merge.mergeSideDiagnostics.differentSources")
@safe pure unittest
{
    auto host = TwoslashReturn(code: "a", nodes: [
        Node(type: NodeType.error, start: 0, length: 1, text: "e"),
    ]);
    const device = TwoslashReturn(code: "b", nodes: [
        Node(type: NodeType.error, start: 0, length: 1, text: "f"),
    ]);
    assert(mergeSideDiagnostics(host, "host", device, "device") == [0]);
    assert(host.nodes.length == 1 && host.nodes[0].text == "e");
}
