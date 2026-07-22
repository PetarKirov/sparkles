/**
The backend-agnostic twoslash node model — a D port of the reference
`twoslash-protocol` (https://github.com/twoslashes/twoslash).

A `TwoslashReturn` is the *display* source ($(D code), already trimmed with the
twoslash notation comments stripped) plus a flat list of $(LREF Node)s. Each
node is a decoration anchored to a byte range of `code`: a $(B hover) type
popup, a persisted `^?` $(B query), a $(B completion) list, a compiler
$(B error), a $(B highlight) span, or a `// @tag` annotation line.

This module treats the node array as $(B opaque input): how it was produced (the
real TypeScript `twoslash`, or a future D-native `sparkles:dmd-lsp` backend) is
someone else's problem — see issue #120. Only the render side lives here.

$(B Modeling choice — one flat POD, not a tagged union.) The reference models
each node kind as a distinct interface sharing a `NodeBase`. In D that would be
a `SumType`, but `sparkles:wired`'s JSON decode disambiguates a sum by
*probing every variant*, not by a discriminant field — and twoslash nodes
overlap enough (`start`/`length`/`line`/`character` on all of them) that
probing is ambiguous. A flat $(LREF Node) with a $(LREF NodeType) tag decodes
uniformly (each present field fills, absent fields default) and lets every
renderer `final switch` on `type`. See $(MREF sparkles,twoslash,ingest).
*/
module sparkles.twoslash.protocol;

import sparkles.wired.policy : WireOptional;

/**
The twoslash node kinds.

Members are lowercase so they match the reference `type` strings
(`"hover"`, `"query"`, …) verbatim under wired's default `CaseStyle.original` —
no per-member `@WireName` needed. A round-trip test guards that assumption.
*/
enum NodeType : ubyte
{
    hover,      /// inline type-on-hover popup
    query,      /// a persisted `^?` popup rendered below its line
    completion, /// an autocomplete list at a caret
    error,      /// a compiler diagnostic (wavy underline + message)
    highlight,  /// a `^^^` highlighted span (no popup)
    tag,        /// a `// @name: text` annotation line
}

/// One candidate in a $(LREF NodeType.completion) node's list. Extra reference
/// fields (`kindModifiers`, `sortText`) are ignored on decode.
struct Completion
{
    string name;              /// the inserted text
    @WireOptional() string kind; /// TS symbol kind (`"method"`, `"property"`, …)
}

/**
One twoslash decoration.

A flat POD: only the fields meaningful for `type` are populated; the rest keep
their defaults. `start`/`length` are byte offsets into `TwoslashReturn.code`;
`line`/`character` are 0-based. Every field except the five universal ones
($(D type), $(D start), $(D length), $(D line), $(D character)) is
`@WireOptional` because it is absent on most node kinds.
*/
struct Node
{
    NodeType type; /// which decoration this is
    size_t start;  /// byte offset into `code`
    size_t length; /// byte length of the anchored span
    size_t line;      /// 0-based line of `start`
    size_t character; /// 0-based column of `start`

    /// hover/query type signature, error message, or tag text.
    @WireOptional() string text;
    /// hover/query attached JSDoc description, if any.
    @WireOptional() string docs;
    /// hover/query JSDoc tags: each inner array is `[name, text?]` (the wire
    /// shape `[name, text][]`; e.g. `["param", "value - the wrapped object"]`).
    /// The name is bare (no leading `@`); the renderer prepends it.
    @WireOptional() string[][] tags;

    /// error level: `"error"` (default) | `"warning"` | `"suggestion"` | `"message"`.
    @WireOptional() string level;
    /// error diagnostic code (0 when absent).
    @WireOptional() int code;
    /// error identifier.
    @WireOptional() string id;

    /// completion candidates.
    @WireOptional() Completion[] completions;
    /// the letters already typed before the caret (for filtering).
    @WireOptional() string completionsPrefix;

    /// tag name (the word after `// @`).
    @WireOptional() string name;

    /// Exclusive end offset into `code`.
    size_t end() const @safe pure nothrow @nogc => start + length;
}

/// The full twoslash payload: the display source plus its flat node list.
struct TwoslashReturn
{
    string code;   /// the trimmed display source (notation already stripped)
    Node[] nodes;  /// the flat decoration list
}

@("protocol.Node.end")
@safe pure nothrow @nogc
unittest
{
    const n = Node(type: NodeType.highlight, start: 5, length: 6);
    assert(n.end == 11);
    assert(Node(start: 3, length: 0).end == 3);
}

@("protocol.NodeType.members")
@safe pure nothrow @nogc
unittest
{
    // The lowercase spelling is load-bearing (it is the wire representation).
    assert(NodeType.hover.stringof == "hover");
    static assert(NodeType.max == NodeType.tag);
}
