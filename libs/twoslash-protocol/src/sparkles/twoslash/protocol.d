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

import sparkles.wired.policy : WireOptional, WireSkip;

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
    @WireOptional(WireSkip.whenDefault) string kind; /// TS symbol kind (`"method"`, `"property"`, …)
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
    ///
    /// $(B Lazy convention): a hover node whose `text` (and `docs`/`tags`)
    /// are empty is a $(I lazy span) — the producer declared where a hover
    /// lives without resolving its content (`twoslash-extract --lazy` /
    /// `--serve`). Renderers still mark the span (the discoverability
    /// underline) but suppress the empty popup; a live consumer fills the
    /// content in on demand.
    @WireOptional(WireSkip.whenDefault) string text;
    /// hover/query attached JSDoc description, if any.
    @WireOptional(WireSkip.whenDefault) string docs;
    /// hover/query JSDoc tags: each inner array is `[name, text?]` (the wire
    /// shape `[name, text][]`; e.g. `["param", "value - the wrapped object"]`).
    /// The name is bare (no leading `@`); the renderer prepends it.
    @WireOptional(WireSkip.whenDefault) string[][] tags;

    /// error level: `"error"` (default) | `"warning"` | `"suggestion"` | `"message"`.
    @WireOptional(WireSkip.whenDefault) string level;
    /// error diagnostic code (0 when absent).
    @WireOptional(WireSkip.whenDefault) int code;
    /// error identifier.
    @WireOptional(WireSkip.whenDefault) string id;

    /// completion candidates.
    @WireOptional(WireSkip.whenDefault) Completion[] completions;
    /// the letters already typed before the caret (for filtering).
    @WireOptional(WireSkip.whenDefault) string completionsPrefix;

    /// tag name (the word after `// @`).
    @WireOptional(WireSkip.whenDefault) string name;

    /// hover/query structured signature layout (`TIP5`). Absent on every
    /// non-function hover and on every payload predating it.
    @WireOptional(WireSkip.whenDefault) SignatureLayout signature;

    /// Exclusive end offset into `code`.
    size_t end() const @safe pure nothrow @nogc => start + length;
}

/// Where a signature may break, what of it collapses, and the effects and
/// contracts lifted out of its text (`TIP5`).
///
/// Every offset indexes the node's own `text`, which stays exactly what a
/// renderer would print unaided — collapsing a run means *hiding* a range, so
/// offsets never shift when the reader expands it again, and a consumer that
/// ignores this field renders precisely what it always did.
struct SignatureLayout
{
    /// Parenthesized lists the renderer may explode one item per line.
    @WireOptional(WireSkip.whenDefault) BreakGroup[] groups;
    /// Places a line may break, always *before* the offset.
    @WireOptional(WireSkip.whenDefault) BreakPoint[] breaks;
    /// Runs the renderer may replace with a short form until expanded.
    @WireOptional(WireSkip.whenDefault) Abbrev[] abbrevs;
    /// The four effect attributes, as data rather than trailing words.
    @WireOptional(WireSkip.whenDefault) Effects effects;
    /// `in`/`out` contracts, as written.
    @WireOptional(WireSkip.whenDefault) Contract[] contracts;
    /// A template's `if (…)` body, empty when there is none.
    @WireOptional(WireSkip.whenDefault) string constraint;
}

/// ditto
struct BreakGroup
{
    uint open;  /// byte offset of `(`
    uint close; /// byte offset of `)`
    /// Staging order, not nesting: the runtime parameter list (0) explodes
    /// before the template one (1).
    @WireOptional(WireSkip.whenDefault) ubyte stage;
}

/// ditto
struct BreakPoint
{
    uint offset;
    @WireOptional(WireSkip.whenDefault) ubyte group; /// index into `groups`
}

/// ditto
struct Abbrev
{
    uint offset;
    uint length;
    /// What to show while collapsed (`"…"`), or empty to elide the run.
    @WireOptional(WireSkip.whenDefault) string shortText;
    /// `"template"` (a nested argument list) or `"module"` (a qualifier).
    @WireOptional(WireSkip.whenDefault) string kind;
}

/// ditto
struct EffectSpan
{
    uint offset;
    uint length; /// separator included, so excising leaves no double space
}

/// ditto
struct Effects
{
    /// `"@safe"` | `"@trusted"` | `"@system"`; empty when not yet determined.
    @WireOptional(WireSkip.whenDefault) string trust;
    @WireOptional(WireSkip.whenDefault) bool isPure;
    @WireOptional(WireSkip.whenDefault) bool isNothrow;
    @WireOptional(WireSkip.whenDefault) bool isNogc;
    /// The attributes are inferred per instantiation and this is the
    /// uninstantiated template, so a `false` above means "not yet known"
    /// rather than "not so" — render those as unknown, not as a denial.
    @WireOptional(WireSkip.whenDefault) bool inferred;
    @WireOptional(WireSkip.whenDefault) EffectSpan[] spans;
}

/// ditto
struct Contract
{
    /// `"in"` or `"out"`.
    string kind;
    /// The `r` of `out (r; …)`; empty for `in` and for `out (; …)`.
    @WireOptional(WireSkip.whenDefault) string resultId;
    /// The expression, or the whole block when `isBlock`.
    @WireOptional(WireSkip.whenDefault) string text;
    @WireOptional(WireSkip.whenDefault) bool isBlock;
}

/// The full twoslash payload: the display source plus its flat node list.
struct TwoslashReturn
{
    string code;   /// the trimmed display source (notation already stripped)
    Node[] nodes;  /// the flat decoration list

    /// Highlighting language of `code` (`"d"`, `"typescript"`, …). Empty means
    /// the TypeScript legacy — every payload predating this field. Renderers
    /// go through $(LREF effectiveLanguage), never this field directly.
    /// `whenDefault`: an unset field encodes to no key at all, so re-encoded
    /// legacy payloads keep their reference shape (plain strings are never
    /// "empty" under wired's `whenEmpty`, which only covers `Nullable`-likes).
    @WireOptional(WireSkip.whenDefault) string language;

    /// Coordinate system of every node's `start`/`length`: `"utf-8"` (byte
    /// offsets into `code` — what D producers emit and what renderers consume)
    /// or empty/`"utf-16"` (the TypeScript legacy; ingest normalizes it, see
    /// $(REF utf16ToUtf8Offsets, sparkles,twoslash,ingest)).
    @WireOptional(WireSkip.whenDefault) string offsetEncoding;

    /// The language to highlight `code` (and popup signatures) as.
    string effectiveLanguage() const @safe pure nothrow @nogc
        => language.length ? language : "typescript";
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

@("protocol.TwoslashReturn.effectiveLanguage")
@safe pure nothrow @nogc
unittest
{
    // Absent language means the TypeScript legacy; set means itself.
    assert(TwoslashReturn().effectiveLanguage == "typescript");
    assert(TwoslashReturn(language: "d").effectiveLanguage == "d");
}
