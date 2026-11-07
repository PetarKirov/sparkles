/** SDL semantic values and the owning ordered arena document, whose cells a
re-parsed document shares with the one it was made from (editing §10.1). */
module sparkles.wired.sdl.document;

import core.time : Duration;
import std.datetime.date : Date;
import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;

import sparkles.base.text.lineindex : LineIndex;
import sparkles.base.text.span : TextSpan;

/// Exact semantic kind retained for every SDL scalar.
enum SdlScalarKind : ubyte
{
    none, /// No payload; the `.init` of an unset scalar.
    null_, /// `null`.
    boolean, /// `bool`.
    string_, /// Decoded UTF-8 text.
    character, /// One Unicode scalar (`dchar`).
    integer, /// `int`.
    longInteger, /// `long` (`L` suffix).
    float_, /// `float` (`F` suffix).
    double_, /// `double` (no suffix or `D`).
    decimal, /// `real` (`BD` suffix).
    binary, /// Bytes from a Base64 literal.
    date, /// `Date`.
    dateTime, /// `SdlDateTime`.
    zonedDateTime, /// `SdlZonedDateTime`.
    duration, /// `Duration`.
}

/// A namespace plus local name. An empty namespace is an ordinary SDL name.
struct SdlQualifiedName
{
    const(char)[] namespace_; /// Namespace prefix; empty for an unnamespaced name.
    const(char)[] localName; /// Name after the prefix.

    /// Full identity equality; namespaces are never implicit wildcards.
    bool opEquals(scope const SdlQualifiedName rhs) const scope
        @safe pure nothrow @nogc
        => namespace_ == rhs.namespace_ && localName == rhs.localName;
}

/// Namespace matching policy for a qualified-name query.
enum SdlNamespaceMatch : ubyte
{
    exact, /// The namespace must match exactly, including empty.
    wildcard, /// Any namespace matches.
}

/** A lookup-only qualified-name query.

`wildcard` matches every namespace for `name.localName`. It is deliberately a
query option and cannot be stored as an SDL qualified name.
*/
struct SdlNameQuery
{
    SdlQualifiedName name; /// The name to look up.
    SdlNamespaceMatch namespaceMatch; /// How `name.namespace_` is compared.

    /// Constructs an exact full-qualified-name query.
    this(return scope SdlQualifiedName name) @safe pure nothrow @nogc
    {
        this.name = name;
    }

    /// Constructs an explicit namespace-wildcard query for `localName`.
    static SdlNameQuery anyNamespace(return scope const(char)[] localName)
        @safe pure nothrow @nogc
    {
        SdlNameQuery result = SdlNameQuery(SdlQualifiedName(null, localName));
        result.namespaceMatch = SdlNamespaceMatch.wildcard;
        return result;
    }

    private bool matches(scope const SdlQualifiedName candidate) const scope
        @safe pure nothrow @nogc
        => candidate.localName == name.localName
            && (namespaceMatch == SdlNamespaceMatch.wildcard
                || candidate.namespace_ == name.namespace_);
}

/** One source position: zero-based byte offset and one-based display position.

A position is computed from a byte offset on demand (`SdlDocument.position`,
`SdlLexer.position`); an `SdlError` carries its own. Columns count one per
UTF-8 sequence and one per invalid byte from the start of the line.
*/
struct SdlPosition
{
    size_t byteOffset; /// Zero-based offset into the original source bytes.
    uint line = 1; /// One-based line; each logical newline counts once.
    uint column = 1; /// One-based column in Unicode scalars.
}

/** Half-open byte range of a document's source.

`SdlSpan.init` is invalid: the span of a value that came from no source, such
as a standalone scalar or an encoded document. Offsets fit in a `uint`; the
parser rejects longer sources with `allocationFailed`.
*/
struct SdlSpan
{
    TextSpan bytes; /// The byte range; invalid when the value has no source.

    /// Constructs `[start, end)`; `start <= end < uint.max`.
    this(size_t start, size_t end) @safe pure nothrow @nogc
    in (start <= end && end < uint.max, "SDL span offsets out of range")
    {
        bytes = TextSpan(cast(uint) start, cast(uint) end);
    }

    /// Zero-width span at `offset`.
    static SdlSpan at(size_t offset) @safe pure nothrow @nogc
        => SdlSpan(offset, offset);

    /// First byte offset inside the range.
    uint startOffset() const scope @safe pure nothrow @nogc => bytes.startOffset;
    /// First byte offset after the range.
    uint endOffset() const scope @safe pure nothrow @nogc => bytes.endOffset;
    /// Whether the span names source bytes at all.
    bool isValid() const scope @safe pure nothrow @nogc => bytes.isValid;
    /// Number of bytes covered; `0` for an invalid span.
    size_t length() const scope @safe pure nothrow @nogc => bytes.length;
    /// The covered bytes of `text`, the source the span was made from.
    const(char)[] sliceOf(return scope const(char)[] text) const @safe pure nothrow @nogc
    in (isValid && endOffset <= text.length, "span outside the text")
        => text[startOffset .. endOffset];
}

/// Comment syntax family, as SDE6 reports it.
enum SdlCommentKind : ubyte
{
    line, /// `#`, `//` or `--`, through the end of its line.
    block, /// `/* … */`, possibly spanning lines.
}

/// One comment the lexer consumed, in source order (editing SDE6).
struct SdlComment
{
    SdlSpan span; /// The comment's bytes, delimiters included, newline excluded.
    SdlCommentKind kind; /// Line or block.
}

/** A local civil date-time with exact hectonanosecond fractional precision.

`fractionHnsecs` is the nonnegative fraction after `second` and must be below
10,000,000. The parser additionally constrains date-time literals to their
specified 1-3 decimal digits.
*/
struct SdlDateTime
{
    Date date; /// Civil date.
    ubyte hour; /// Hour, 0-23.
    ubyte minute; /// Minute, 0-59.
    ubyte second; /// Second, 0-59.
    uint fractionHnsecs; /// Fraction of `second` in hectonanoseconds.
}

/** A local SDL date-time plus its original zone spelling.

Named zones remain valid without a host time-zone database. When resolution is
possible, `utcOffset` carries the exact offset and `hasUtcOffset` distinguishes
it from `Duration.zero` as an unknown offset.
*/
struct SdlZonedDateTime
{
    SdlDateTime local; /// Civil date-time in the zone.
    const(char)[] zone; /// Zone exactly as spelled in the source.
    Duration utcOffset; /// Offset from UTC; meaningful only when `hasUtcOffset`.
    bool hasUtcOffset; /// Whether the zone resolved to a known offset.
}

/** One discriminated SDL scalar.

String and binary payloads are borrowed slices. A parsed document owns their
storage; callers constructing standalone values must keep the backing storage
alive through the write.
*/
struct SdlScalar
{
    private SdlScalarKind _kind = SdlScalarKind.null_;
    private SdlSpan _span;
    private union Payload
    {
        bool booleanValue;
        const(char)[] stringValue;
        dchar characterValue;
        int integerValue;
        long longValue;
        float floatValue;
        double doubleValue;
        real decimalValue;
        const(ubyte)[] binaryValue;
        Date dateValue;
        SdlDateTime dateTimeValue;
        SdlZonedDateTime zonedDateTimeValue;
        Duration durationValue;
    }
    private Payload _payload;

    /// Constructs SDL `null`.
    this(typeof(null)) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.null_;
    }

    /// Constructs an SDL boolean.
    this(bool value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.boolean;
        _payload.booleanValue = value;
    }

    /// Constructs an SDL string.
    this(return scope const(char)[] value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.string_;
        _payload.stringValue = value;
    }

    /// Constructs an SDL character.
    this(dchar value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.character;
        _payload.characterValue = value;
    }

    /// Constructs an SDL 32-bit integer.
    this(int value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.integer;
        _payload.integerValue = value;
    }

    /// Constructs an SDL 64-bit integer.
    this(long value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.longInteger;
        _payload.longValue = value;
    }

    /// Constructs an SDL binary32 value.
    this(float value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.float_;
        _payload.floatValue = value;
    }

    /// Constructs an SDL binary64 value.
    this(double value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.double_;
        _payload.doubleValue = value;
    }

    /// Constructs an SDL extended-decimal value.
    static SdlScalar decimal(real value) @safe pure nothrow @nogc
    {
        SdlScalar result;
        result._kind = SdlScalarKind.decimal;
        result._payload.decimalValue = value;
        return result;
    }

    /// Constructs an SDL binary value.
    this(return scope const(ubyte)[] value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.binary;
        _payload.binaryValue = value;
    }

    /// Constructs an SDL date.
    this(Date value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.date;
        _payload.dateValue = value;
    }

    /// Constructs an SDL local date-time.
    this(SdlDateTime value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.dateTime;
        _payload.dateTimeValue = value;
    }

    /// Constructs an SDL zoned date-time.
    this(SdlZonedDateTime value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.zonedDateTime;
        _payload.zonedDateTimeValue = value;
    }

    /// Constructs an SDL duration.
    this(Duration value) @safe pure nothrow @nogc
    {
        _kind = SdlScalarKind.duration;
        _payload.durationValue = value;
    }

    /// The active payload kind.
    SdlScalarKind kind() const scope @safe pure nothrow @nogc => _kind;

    package static SdlScalar invalidScalar() @safe pure nothrow @nogc
    {
        SdlScalar result;
        result._kind = SdlScalarKind.none;
        return result;
    }

    /// Exact original token span; default/standalone values have an empty span.
    SdlSpan span() const scope @safe pure nothrow @nogc => _span;

    package void setSpan(SdlSpan value) scope @safe pure nothrow @nogc
    {
        _span = value;
    }

    /// Moves the span by `delta` bytes, as a shared run reads it (editing §10.1).
    package void shiftSpan(uint delta) scope @safe pure nothrow @nogc
    {
        if (delta)
            _span = shiftedBy(_span, delta);
    }


    /** Package seam for the incremental reader (editing §10): the borrowed
    bytes of the payload — a string, a binary value, or a zone's spelling —
    or `null` for a kind that borrows none. */
    package const(ubyte)[] borrowedBytes() const @safe pure nothrow @nogc return scope
    {
        switch (_kind)
        {
        case SdlScalarKind.string_:
            return cast(const(ubyte)[]) stringValue;
        case SdlScalarKind.binary:
            return binary;
        case SdlScalarKind.zonedDateTime:
            return cast(const(ubyte)[]) (() @trusted => _payload.zonedDateTimeValue.zone)();
        default:
            return null;
        }
    }

    /// ditto: points the borrowed payload at `bytes`, a copy of it.
    package void rebind(const(ubyte)[] bytes) @safe pure nothrow @nogc
    in (bytes.length == borrowedBytes.length)
    {
        // Narrow trust: each write replaces the active member's slice with
        // one of the same length, so the union keeps its kind.
        switch (_kind)
        {
        case SdlScalarKind.string_:
            () @trusted { _payload.stringValue = cast(const(char)[]) bytes; }();
            break;
        case SdlScalarKind.binary:
            () @trusted { _payload.binaryValue = bytes; }();
            break;
        case SdlScalarKind.zonedDateTime:
            () @trusted { _payload.zonedDateTimeValue.zone = cast(const(char)[]) bytes; }();
            break;
        default:
            break;
        }
    }

    /// Active boolean payload.
    bool boolean() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.boolean)
    {
        return (() @trusted => _payload.booleanValue)();
    }

    /// Active string payload.
    const(char)[] stringValue() const @safe pure nothrow @nogc return scope
    in (_kind == SdlScalarKind.string_)
    {
        return (() @trusted => _payload.stringValue)();
    }

    /// Active character payload.
    dchar character() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.character)
    {
        return (() @trusted => _payload.characterValue)();
    }

    /// Active 32-bit integer payload.
    int integer() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.integer)
    {
        return (() @trusted => _payload.integerValue)();
    }

    /// Active 64-bit integer payload.
    long longInteger() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.longInteger)
    {
        return (() @trusted => _payload.longValue)();
    }

    /// Active binary32 payload.
    float floatValue() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.float_)
    {
        return (() @trusted => _payload.floatValue)();
    }

    /// Active binary64 payload.
    double doubleValue() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.double_)
    {
        return (() @trusted => _payload.doubleValue)();
    }

    /// Active extended-decimal payload.
    real decimalValue() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.decimal)
    {
        return (() @trusted => _payload.decimalValue)();
    }

    /// Active binary payload.
    const(ubyte)[] binary() const @safe pure nothrow @nogc return scope
    in (_kind == SdlScalarKind.binary)
    {
        return (() @trusted => _payload.binaryValue)();
    }

    /// Active date payload.
    Date date() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.date)
    {
        return (() @trusted => _payload.dateValue)();
    }

    /// Active local date-time payload.
    SdlDateTime dateTime() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.dateTime)
    {
        return (() @trusted => _payload.dateTimeValue)();
    }

    /// Active zoned date-time payload.
    SdlZonedDateTime zonedDateTime() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.zonedDateTime)
    {
        return (() @trusted => _payload.zonedDateTimeValue)();
    }

    /// Active duration payload.
    Duration duration() const scope @safe pure nothrow @nogc
    in (_kind == SdlScalarKind.duration)
    {
        return (() @trusted => _payload.durationValue)();
    }
}

package struct SdlNodeCell
{
    SdlQualifiedName qualifiedName;
    SdlSpan nameSpan;
    SdlSpan span;
    size_t valueStart;
    size_t valueCount;
    size_t attributeStart;
    size_t attributeCount;
    /// The nodes of its preorder subtree, itself included: its first child
    /// follows it, and each child's next sibling follows that child's subtree.
    size_t subtreeSize = 1;
    size_t childCount;
    uint depth;
    /// Source had an explicit child block (canonical writer emits braces
    /// even when the block was empty).
    bool hasBlock;
    /// The node's bytes and nothing else's (editing §2), clipped to content.
    SdlSpan extent;
    /// The `{` and `}` tokens of the child block; invalid without one.
    SdlSpan openBrace, closeBrace;
    /// The `;`, newline or zero-width end that ends the declaration (for a
    /// node with a block, the one after its `}`).
    SdlSpan terminator;
    /// No other node's tokens and no enclosing brace share its lines.
    bool aloneOnLines;
}

package struct SdlValueCell
{
    SdlScalar value;
}

package struct SdlAttributeCell
{
    SdlQualifiedName qualifiedName;
    SdlSpan nameSpan;
    SdlSpan span;
    SdlScalar value;
}

/// `span` moved by `delta` bytes, modulo 2³²; an invalid span stays invalid.
package SdlSpan shiftedBy(SdlSpan span, uint delta) @safe pure nothrow @nogc
{
    if (delta == 0 || !span.isValid)
        return span;
    SdlSpan result;
    result.bytes = TextSpan(span.startOffset + delta, span.endOffset + delta);
    return result;
}

/// `name`'s spelling in `source`, read through `nameSpan`: the lengths of
/// `name`'s halves are all it reads of `name` (editing §10.1).
package SdlQualifiedName respelled(scope const SdlQualifiedName name, SdlSpan nameSpan,
    return scope const(char)[] source) @safe pure nothrow @nogc
{
    const start = nameSpan.startOffset, end = nameSpan.endOffset;
    return SdlQualifiedName(source[start .. start + name.namespace_.length],
        source[end - name.localName.length .. end]);
}

/** One batch of cells, built once by a parse or a region re-parse and never
changed after (editing §10.1).

A block is reference-counted: every document whose runs read it holds one
reference, and the last to drop it frees it, through the copy of the
allocator that made it, which a stateful allocator keeps right after the
header in the header's own allocation. Payloads of its cells lie in its pool.
*/
package struct SdlBlock
{
    SdlNodeCell[] nodes;
    SdlValueCell[] values;
    SdlAttributeCell[] attributes;
    SdlComment[] comments;
    /// Line starts: a parse's whole table (`lines`), or a region's.
    const(size_t)[] lineStarts;
    ubyte[] pool;
    /// A parse's line table, which `lineStarts` views.
    LineIndex lines;
    /// Every allocation but the header, freed with it.
    void[][6] owned;
    /// The header's own allocation.
    void[] header;
    /// The bytes it holds, for the re-parse's retention bound (§10.1).
    size_t bytes;
    /// The allocator type that made it.
    immutable(void)* allocatorTag;
    shared size_t refs;
}

/// The address that names `Allocator`'s type in `SdlBlock.allocatorTag`.
package template allocatorTagOf(Allocator)
{
    private immutable ubyte tag;
    enum allocatorTagOf = &tag;
}

/** A range `[lo, hi)` of one block's cells, seen at logical index `base`
with `delta` added to every valid offset (editing §10.1).

A node run also places its nodes' values and attributes: the block's values
from `valueLo` on are logical values from `valueBase` on, and likewise for
attributes. Comment and line runs leave those fields zero.
*/
package struct SdlRun
{
    const(SdlBlock)* block;
    uint lo, hi;
    uint base;
    uint delta;
    uint valueLo, valueBase;
    uint attributeLo, attributeBase;
}

/// The last run whose `key` is at most `index`.
package size_t runOf(string key)(scope const(SdlRun)[] runs, size_t index)
    @safe pure nothrow @nogc
in (runs.length != 0)
{
    size_t lo = 0, hi = runs.length;
    while (hi - lo > 1)
    {
        const mid = lo + (hi - lo) / 2;
        if (__traits(getMember, runs[mid], key) <= index)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

/** A document's immovable core: its source, line table and cells (performance
SDP3).

It lives in one heap block the document points at, so moving a document never
invalidates a view, and its type does not depend on the allocator, so a view
can reach the source and line table without being a template.

A **flat** core — a full parse's, or an encoded document's — holds its cells
in the `flat` arrays, which views index directly. A **shared** core, made by a
region re-parse, leaves them empty and places its cells through runs over
blocks it may share with other documents (editing §10.1); its accessors find
the run that holds an index and apply its shift and bases. Read cells through
the accessors (`nodeAt`, `valueAt`, `attributeAt`, `commentAt`, `lineStart`),
which serve both.
*/
package struct SdlCore
{
    /// A flat core's cells; empty for a shared core.
    SdlNodeCell[] flatNodes;
    /// ditto
    SdlValueCell[] flatValues;
    /// ditto
    SdlAttributeCell[] flatAttributes;
    /// ditto
    const(SdlComment)[] flatComments;
    /// A flat parse's line table; `null` for an encoded or a shared core.
    const(LineIndex)* flatLines;
    /// The source every span indexes; `null` for an encoded document.
    const(char)[] source;
    /// The bytes nodes may occupy: the source after any byte-order mark,
    /// or an embedded recipe's text.
    SdlSpan content;
    /// Where line 0 starts: after any byte-order mark.
    size_t lineZero;
    /// A shared core's runs and counts.
    const(SdlRun)[] nodeRuns, commentRuns, lineRuns;
    /// ditto
    size_t nodeTotal, valueTotal, attributeTotal, commentTotal, lineTotal;
    /// Every block the core holds a reference to, by ascending address.
    const(SdlBlock*)[] blocks;
    /// `blocks`' storage for a flat parse's one block.
    const(SdlBlock)*[1] onlyBlock;

    /// Whether the cells are the `flat` arrays.
    pragma(inline, true)
    bool flat() const scope @safe pure nothrow @nogc => nodeRuns.length == 0;

    /// The number of nodes, the root included.
    size_t nodeCount() const scope @safe pure nothrow @nogc
        => flat ? flatNodes.length : nodeTotal;
    /// The number of values, of attributes, of comments and of lines.
    pragma(inline, true)
    size_t valueCount() const scope @safe pure nothrow @nogc
        => flat ? flatValues.length : valueTotal;
    /// ditto
    pragma(inline, true)
    size_t attributeCount() const scope @safe pure nothrow @nogc
        => flat ? flatAttributes.length : attributeTotal;
    /// ditto
    size_t commentCount() const scope @safe pure nothrow @nogc
        => flat ? flatComments.length : commentTotal;
    /// ditto
    size_t lineCount() const scope @safe pure nothrow @nogc
        => flat ? (flatLines is null ? 0 : flatLines.lineCount) : lineTotal;

    /** Node `index`'s cell as its block stores it, and the run that places it,
    `null` for a flat core: views read one field through it, shifting a span
    by `run.delta` and spelling a name from `source`. The shared path stays
    out of line, so a flat core's reads inline to an array index. */
    pragma(inline, true)
    const(SdlNodeCell)* rawNode(size_t index, out const(SdlRun)* run) const @trusted
        pure nothrow @nogc
    {
        // Narrow trust: the address of a cell of this core, which outlives
        // the views it serves.
        if (flat)
            return &flatNodes[index];
        return sharedNode(index, run);
    }

    /// ditto, for attribute `index` in document order.
    pragma(inline, true)
    const(SdlAttributeCell)* rawAttribute(size_t index, out const(SdlRun)* run) const @trusted
        pure nothrow @nogc
    {
        if (flat)
            return &flatAttributes[index];
        return sharedAttribute(index, run);
    }

    pragma(inline, false)
    package const(SdlNodeCell)* sharedNode(size_t index, out const(SdlRun)* run) const
        @trusted pure nothrow @nogc
    {
        run = &nodeRuns[runOf!"base"(nodeRuns, index)];
        return &run.block.nodes[run.lo + (index - run.base)];
    }

    pragma(inline, false)
    package const(SdlAttributeCell)* sharedAttribute(size_t index, out const(SdlRun)* run)

        const @trusted pure nothrow @nogc
    {
        run = &nodeRuns[runOf!"attributeBase"(nodeRuns, index)];
        return &run.block.attributes[run.attributeLo + (index - run.attributeBase)];
    }

    /** Node `index` as a full parse would hold it: spans shifted, its name
    spelled from `source`, and `valueStart` and `attributeStart` logical. */
    SdlNodeCell nodeAt(size_t index) const @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        SdlNodeCell cell = (() @trusted => *rawNode(index, run))();
        if (run is null)
            return cell;
        cell.nameSpan = shiftedBy(cell.nameSpan, run.delta);
        cell.span = shiftedBy(cell.span, run.delta);
        cell.extent = shiftedBy(cell.extent, run.delta);
        cell.openBrace = shiftedBy(cell.openBrace, run.delta);
        cell.closeBrace = shiftedBy(cell.closeBrace, run.delta);
        cell.terminator = shiftedBy(cell.terminator, run.delta);
        cell.qualifiedName = (() @trusted => respelled(cell.qualifiedName, cell.nameSpan,
            source))();
        cell.valueStart = run.valueBase + (cell.valueStart - run.valueLo);
        cell.attributeStart = run.attributeBase + (cell.attributeStart - run.attributeLo);
        return cell;
    }

    /// Node `index`'s subtree size, without resolving the rest of it.
    pragma(inline, true)
    size_t subtreeSizeAt(size_t index) const scope @safe pure nothrow @nogc
        => flat ? flatNodes[index].subtreeSize : sharedSubtreeSize(index);

    pragma(inline, false)
    private size_t sharedSubtreeSize(size_t index) const scope @trusted pure nothrow @nogc
    {
        const(SdlRun)* run;
        return sharedNode(index, run).subtreeSize;
    }


    /// Value `index` in document order, its span shifted.
    SdlValueCell valueAt(size_t index) const @safe pure nothrow @nogc
    {
        if (flat)
            return (() @trusted => flatValues[index])();
        const run = nodeRuns[runOf!"valueBase"(nodeRuns, index)];
        SdlValueCell cell = (() @trusted
            => run.block.values[run.valueLo + (index - run.valueBase)])();
        cell.value.shiftSpan(run.delta);
        return cell;
    }

    /// Attribute `index` in document order, its spans shifted and its name
    /// spelled from `source`.
    SdlAttributeCell attributeAt(size_t index) const @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        SdlAttributeCell cell = (() @trusted => *rawAttribute(index, run))();
        if (run is null)
            return cell;
        cell.nameSpan = shiftedBy(cell.nameSpan, run.delta);
        cell.span = shiftedBy(cell.span, run.delta);
        cell.value.shiftSpan(run.delta);
        cell.qualifiedName = (() @trusted => respelled(cell.qualifiedName, cell.nameSpan,
            source))();
        return cell;
    }

    /// Comment `index` in source order, its span shifted.
    SdlComment commentAt(size_t index) const scope @safe pure nothrow @nogc
    {
        if (flat)
            return flatComments[index];
        const run = commentRuns[runOf!"base"(commentRuns, index)];
        const comment = (() @trusted => run.block.comments[run.lo + (index - run.base)])();
        return SdlComment(shiftedBy(comment.span, run.delta), comment.kind);
    }

    /// Every comment, in source order.
    SdlCommentRange comments() const return scope @safe pure nothrow @nogc
        => (() @trusted => SdlCommentRange(&this, 0, commentCount))();

    /// The start of logical line `line` (0-based).

    size_t lineStart(size_t line) const scope @safe pure nothrow @nogc
    {
        if (flat)
            return flatLines.lineStart(line);
        const run = lineRuns[runOf!"base"(lineRuns, line)];
        return cast(uint)((() @trusted => run.block.lineStarts[run.lo + (line - run.base)])()
            + run.delta);
    }

    /// The position of byte `offset` (at most the source length).
    SdlPosition position(size_t offset) const scope @safe pure nothrow @nogc
    {
        if (source.length == 0 || offset <= lineZero)
            return SdlPosition(offset, 1, 1);
        const at = offset > source.length ? source.length : offset;
        if (flat)
        {
            const lc = flatLines.lineColAt(at, source);
            return SdlPosition(offset, cast(uint)(lc.line + 1), cast(uint)(lc.column + 1));
        }
        import sparkles.base.text.utf8 : utf8SequenceLength;

        // The last line that starts at or before `at`, then its UTF-8 columns,
        // as `LineIndex.lineColAt` counts them.
        size_t lo = 0, hi = lineCount;
        while (hi - lo > 1)
        {
            const mid = lo + (hi - lo) / 2;
            if (lineStart(mid) <= at)
                lo = mid;
            else
                hi = mid;
        }
        size_t column;
        for (size_t i = lineStart(lo); i < at; column++)
        {
            const width = source[i] < 0x80 ? 1 : utf8SequenceLength(source, i);
            i += width ? width : 1;
        }
        return SdlPosition(offset, cast(uint)(lo + 1), cast(uint)(column + 1));
    }

    /** Package seam for the region re-parse: the core's node, comment and
    line runs, a flat parse's described as one run each over its block in
    `scratch`. */
    void runsInto(ref SdlRun[3] scratch, out const(SdlRun)[] nodes,
        out const(SdlRun)[] comments, out const(SdlRun)[] lines) const return @safe pure nothrow @nogc
    in (blocks.length != 0, "an encoded document has no blocks")
    {
        if (!flat)
        {
            nodes = nodeRuns;
            comments = commentRuns;
            lines = lineRuns;
            return;
        }
        const block = blocks[0];
        scratch[0] = SdlRun(block, 0, cast(uint) flatNodes.length, 0);
        scratch[1] = SdlRun(block, 0, cast(uint) flatComments.length, 0);
        scratch[2] = SdlRun(block, 0, cast(uint) flatLines.lineCount, 0);
        nodes = (() @trusted => scratch[0 .. 1])();
        comments = (() @trusted => scratch[1 .. 2])();
        lines = (() @trusted => scratch[2 .. 3])();
    }
}

/** Owning, movable, non-copyable parsed SDL document.

The document owns the text it was parsed from (`source`), and every span is a
byte range into it; `position` turns an offset into a line and column. The
synthetic root always has the empty/default qualified name and a zero-width
span at the source start after UTF-8 BOM handling. A document re-parsed after
an edit shares its unchanged cells with the one it was made from (editing
§10.1).
*/
struct SdlDocument(Allocator = Mallocator)
{
    import sparkles.base.buffer : UniqueBuffer;

    static if (stateSize!Allocator)
        package Allocator alloc;
    else
        package alias alloc = Allocator.instance;

    package SdlCore* core;
    /// The pool of the block a parse fills, and of a shared core's own block.
    package ubyte[] pool;
    /// The block a parse fills, until the core holds it.
    private SdlBlock* building;
    private void[] coreBlock;
    /// A shared core's runs and block list, in one allocation.
    private void[] tableBlock;
    /// A shared core's source name and source copy, in one allocation.
    private void[] textBlock;
    /// A shared core's source, when the caller handed it over.
    private UniqueBuffer!char adoptedText;
    package const(char)[] ownedSourceName;

    @disable this(this);

    /// Move assignment transfers every allocation and allocator state.
    void opAssign(SdlDocument rhs)
    {
        import std.algorithm.mutation : swap;

        static if (stateSize!Allocator)
            swap(alloc, rhs.alloc);
        swap(core, rhs.core);
        swap(pool, rhs.pool);
        swap(building, rhs.building);
        swap(coreBlock, rhs.coreBlock);
        swap(tableBlock, rhs.tableBlock);
        swap(textBlock, rhs.textBlock);
        swap(adoptedText, rhs.adoptedText);
        swap(ownedSourceName, rhs.ownedSourceName);
    }

    /// Whether this document contains its synthetic root.
    bool valid() const scope @safe pure nothrow @nogc
        => core !is null && core.nodeCount != 0;

    /** Borrowed synthetic root view, valid only while this document is.

    `scope return` binds the view to the document object rather than to its
    core, so no view outlives the owner that frees it. Narrow trust: the core
    pointer is a field of a `scope` `this`, which dip1000 would only let
    escape under `return scope`, the weaker arena-lifetime binding. */
    SdlNode root() scope return const @safe pure nothrow @nogc
    in (valid, "empty document has no root")
        => (() @trusted => SdlNode(core, 0))();

    /// Owned source label supplied to the parser.
    const(char)[] sourceName() const return scope @safe pure nothrow @nogc
        => ownedSourceName;

    /// The text the document owns, which every span indexes.
    const(char)[] source() const return scope @safe pure nothrow @nogc
        => core is null ? null : (() @trusted => core.source)();

    /** The line and column of byte `offset` of `source`.

    Line 1 starts after any byte-order mark; each logical newline (`\n`, `\r`,
    `\r\n`, U+2028, U+2029) starts a line; columns count one per UTF-8 sequence
    and one per invalid byte. */
    SdlPosition position(size_t offset) const scope @safe pure nothrow @nogc
        => core is null ? SdlPosition(offset) : core.position(offset);

    /// Every comment in the source, in source order (editing SDE6).
    SdlCommentRange comments() const return scope @safe pure nothrow @nogc
        => core is null ? SdlCommentRange.init
            : (() @trusted => SdlCommentRange(core, 0, core.commentCount))();

    ~this()
    {
        release();
    }

    /// Frees every arena, keeping a stateful allocator for the next parse.
    package void reset() => release();

    /** Allocates the core, if there is none yet, and a block to fill, with
    the pool and first capacities for its node, value and attribute arrays,
    which the core's `flat` arrays view while the parser fills them; the
    parser grows those (`grow`) and trims them (`finish`, `finishShared`). */
    package bool acquire(size_t nodeCapacity, size_t valueCapacity,
        size_t attributeCapacity, size_t poolBytes)
    {
        if (!acquireCore() || !acquireHeader())
        {
            release();
            return false;
        }
        if (!acquireBlock(building.pool, building.owned[5], poolBytes)
            || !acquireBlock(building.nodes, building.owned[0], nodeCapacity)
            || !acquireBlock(building.values, building.owned[1], valueCapacity)
            || !acquireBlock(building.attributes, building.owned[2], attributeCapacity))
        {
            release();
            return false;
        }
        pool = building.pool;
        core.flatNodes = building.nodes;
        core.flatValues = building.values;
        core.flatAttributes = building.attributes;
        return true;
    }

    /// Doubles `field`'s array of the block being filled, keeping its first
    /// `used` cells.
    package bool grow(string field)(size_t used)
    {
        enum slot = field == "nodes" ? 0 : field == "values" ? 1 : 2;
        alias T = typeof(__traits(getMember, *building, field)[0]);

        const capacity = __traits(getMember, *building, field).length;
        const wanted = capacity < 8 ? 16 : capacity * 2;
        T[] grown;
        void[] grownBlock;
        if (wanted <= capacity || !acquireBlock(grown, grownBlock, wanted))
            return false;
        grown[0 .. used] = __traits(getMember, *building, field)[0 .. used];
        releaseAllocation(building.owned[slot]);
        building.owned[slot] = grownBlock;
        __traits(getMember, *building, field) = grown;
        static if (slot == 0)
            core.flatNodes = grown;
        else static if (slot == 1)
            core.flatValues = grown;
        else
            core.flatAttributes = grown;
        return true;

    }

    /** Trims the filled block's arrays to the cells the parser filled, copies
    its comments, takes its line table, and makes it the flat core's one
    block. */
    package bool finish(size_t nodeCount, size_t valueCount, size_t attributeCount,
        scope const(SdlComment)[] comments, LineIndex lines)
    {
        trim(nodeCount, valueCount, attributeCount);
        if (!acquireBlock(building.comments, building.owned[3], comments.length))
            return false;
        building.comments[] = comments[];
        building.lines = lines;
        building.lineStarts = (() @trusted => building.lines.lineStarts)();
        core.flatComments = building.comments;
        core.flatLines = (() @trusted => &building.lines)();
        core.lineZero = lines.lineStart(0);
        count(lines.lineCount * size_t.sizeof);
        core.onlyBlock[0] = building;
        core.blocks = (() @trusted => core.onlyBlock[])();
        building = null;
        return true;
    }

    /** Trims the filled block to the cells the region re-parse put in it,
    stores its comments and line starts, and makes the core shared: it reads
    its cells through `nodeRuns`, `commentRuns` and `lineRuns`, whose block
    `null` stands for the filled one, and holds `others`, blocks of an older
    document, besides that one (editing §10.1). The source is `adopted`'s,
    taken over, when that holds heap storage, and otherwise a copy of `text`. */

    package bool finishShared(size_t nodeCount, size_t valueCount, size_t attributeCount,
        scope const(SdlComment)[] comments, scope const(size_t)[] lineStarts,
        scope const(SdlRun)[] nodeRuns, scope const(SdlRun)[] commentRuns,
        scope const(SdlRun)[] lineRuns, scope const(SdlBlock*)[] others,
        scope const(char)[] text, scope const(char)[] sourceName,
        ref UniqueBuffer!char adopted, SdlSpan content, size_t lineZero)
    {
        if (!acquireCore())
            return false;
        if (building !is null)
        {
            trim(nodeCount, valueCount, attributeCount);
            size_t[] starts;
            if (!acquireBlock(building.comments, building.owned[3], comments.length)
                || !acquireBlock(starts, building.owned[4], lineStarts.length))
                return false;
            building.comments[] = comments[];
            starts[] = lineStarts[];
            building.lineStarts = starts;
            count(0);
        }

        // The run tables and the block list share one allocation.
        const runCount = nodeRuns.length + commentRuns.length + lineRuns.length;
        const blockCount = others.length + (building !is null);
        SdlRun[] runs;
        if (!acquireBlock(runs, tableBlock, runCount + (blockCount * (SdlBlock*).sizeof
            + SdlRun.sizeof - 1) / SdlRun.sizeof))
            return false;
        auto held = () @trusted {
            return (cast(const(SdlBlock)**)(runs.ptr + runCount))[0 .. blockCount];
        }();
        size_t k;
        foreach (block; others)
            held[k++] = block;
        if (building !is null)
        {
            held[k++] = building;
            // Ascending by address, as `blocks` is kept.
            for (size_t i = k - 1; i > 0 && held[i - 1] > held[i]; i--)
            {
                const swap = held[i - 1];
                held[i - 1] = held[i];
                held[i] = swap;
            }
        }
        size_t at;
        void place(scope const(SdlRun)[] from, ref const(SdlRun)[] to, ref size_t total)
        {
            const start = at;
            foreach (run; from)
            {
                runs[at] = run;
                if (runs[at].block is null)
                    runs[at].block = building;
                at++;
            }
            to = (() @trusted => runs[start .. at])();
            total = from.length ? from[$ - 1].base + (from[$ - 1].hi - from[$ - 1].lo) : 0;
        }
        place(nodeRuns, core.nodeRuns, core.nodeTotal);
        place(commentRuns, core.commentRuns, core.commentTotal);
        place(lineRuns, core.lineRuns, core.lineTotal);

        // The value and attribute totals end the last node run.
        const last = core.nodeRuns[$ - 1];
        const tail = (() @trusted => &last.block.nodes[last.hi - 1])();
        core.valueTotal = last.valueBase + (tail.valueStart + tail.valueCount - last.valueLo);
        core.attributeTotal = last.attributeBase
            + (tail.attributeStart + tail.attributeCount - last.attributeLo);

        // The source: taken over, or copied after the source name. Only heap
        // storage is taken over: an inline buffer would move with the document.
        const adopt = adopted.length && adopted.onHeap;
        ubyte[] owned;
        if (!acquireBlock(owned, textBlock, sourceName.length + (adopt ? 0 : text.length)))
            return false;
        owned[0 .. sourceName.length] = cast(const(ubyte)[]) sourceName[];
        ownedSourceName = (() @trusted => (cast(const(char)*) owned.ptr)[0 .. sourceName.length])();
        if (adopt)
        {
            import core.lifetime : move;

            adoptedText = move(adopted);
            core.source = (() @trusted => adoptedText[])();
        }
        else
        {
            owned[sourceName.length .. $] = cast(const(ubyte)[]) text[];
            core.source = (() @trusted => (cast(const(char)*) owned.ptr
                + sourceName.length)[0 .. text.length])();
        }

        // Only now, past every failure, the core takes its references.
        foreach (block; others)
            retain(block);
        core.blocks = held;
        core.content = content;
        core.lineZero = lineZero;
        core.flatNodes = null;
        core.flatValues = null;
        core.flatAttributes = null;
        core.flatComments = null;
        core.flatLines = null;
        building = null;
        return true;
    }

    /// The bytes `blocks` hold together.
    package static size_t heldBytes(scope const(SdlBlock*)[] blocks) @safe pure nothrow @nogc
    {
        size_t total;
        foreach (block; blocks)
            total += block.bytes;
        return total;
    }

    /// The block being filled, for the region re-parse.
    package const(SdlBlock)* filling() const return scope @safe pure nothrow @nogc
        => building;

    /// Whether `block` was made through this allocator type, so this
    /// document may hold it (editing §10.1).
    package static bool canHold(scope const(SdlBlock)* block) @safe pure nothrow @nogc
        => block.allocatorTag is allocatorTagOf!Allocator;

    /// Records the filled block's size: its allocations, and `extra` more
    /// bytes it holds elsewhere.
    private void count(size_t extra) @safe pure nothrow @nogc
    {
        building.bytes = building.header.length + extra;
        foreach (owned; building.owned)
            building.bytes += owned.length;
    }

    private void trim(size_t nodeCount, size_t valueCount, size_t attributeCount)
    {
        building.nodes = building.nodes[0 .. nodeCount];
        building.values = building.values[0 .. valueCount];
        building.attributes = building.attributes[0 .. attributeCount];
        core.flatNodes = building.nodes;
        core.flatValues = building.values;
        core.flatAttributes = building.attributes;
    }

    /// Allocates the core, unless there is one.
    private bool acquireCore()
    {
        if (core !is null)
            return true;
        SdlCore[] coreSlot;
        if (!acquireBlock(coreSlot, coreBlock, 1))
            return false;
        () @trusted {
            import core.lifetime : emplace;

            emplace(&coreSlot[0]);
            core = &coreSlot[0];
        }();
        return true;
    }

    /// Allocates the header of the block to fill, with a stateful

    /// allocator's copy after it.
    private bool acquireHeader()
    {
        enum headerSize = (SdlBlock.sizeof + 15) & ~size_t(15);
        ubyte[] header;
        void[] owner;
        if (!acquireBlock(header, owner, headerSize + stateSize!Allocator))
            return false;
        () @trusted {
            import core.lifetime : emplace;

            building = cast(SdlBlock*) header.ptr;
            emplace(building);
            static if (stateSize!Allocator)
                emplace(cast(Allocator*)(header.ptr + headerSize), alloc);
        }();
        building.header = owner;
        building.allocatorTag = allocatorTagOf!Allocator;
        building.refs = 1;
        return true;
    }

    private bool acquireBlock(T)(ref T[] target, ref void[] owner, size_t count)
    {
        if (count == 0)
            return true;
        if (count > size_t.max / T.sizeof)
            return false;
        auto block = alloc.allocate(count * T.sizeof);
        if (block is null || block.length < count * T.sizeof)
        {
            static if (__traits(hasMember, Allocator, "deallocate"))
                if (block !is null)
                    () @trusted { alloc.deallocate(block); }();
            return false;
        }
        target = () @trusted {
            return (cast(T*) block.ptr)[0 .. count];
        }();
        owner = block;
        return true;

    }

    /// Takes one more reference to `block`.
    private static void retain(scope const(SdlBlock)* block) @trusted pure nothrow @nogc
    {
        import core.atomic : atomicOp;

        // Narrow trust: the count is the one field a shared block changes.
        atomicOp!"+="((cast(SdlBlock*) block).refs, 1);
    }

    /// Drops one reference to `block`, freeing it with the last.
    private static void drop(scope const(SdlBlock)* block)
    {
        import core.atomic : atomicOp;

        // Narrow trust: as in `retain`; the last holder owns the block.
        auto owned = (() @trusted => cast(SdlBlock*) block)();
        if (atomicOp!"-="(owned.refs, 1) == 0)
            free(owned);
    }

    /// Frees `block` through the allocator copy that made it.
    private static void free(SdlBlock* block)
    {
        enum headerSize = (SdlBlock.sizeof + 15) & ~size_t(15);
        static if (stateSize!Allocator)
        {
            import core.lifetime : move;

            Allocator maker = (() @trusted => move(*cast(Allocator*)(
                cast(ubyte*) block + headerSize)))();
        }
        else
            alias maker = Allocator.instance;
        static if (__traits(hasMember, Allocator, "deallocate"))
        {
            () @trusted { destroy(block.lines); }();
            foreach (ref owned; block.owned)
                if (owned.length)
                    () @trusted { maker.deallocate(owned); }();
            auto header = block.header;
            () @trusted { maker.deallocate(header); }();
        }
    }

    private void release()
    {
        if (core !is null)
            foreach (block; core.blocks)
                drop(block);
        if (building !is null)
            free(building);
        static if (__traits(hasMember, Allocator, "deallocate"))
        {
            releaseAllocation(tableBlock);
            releaseAllocation(textBlock);
            releaseAllocation(coreBlock);
        }
        adoptedText.clear();
        core = null;
        pool = null;
        building = null;
        tableBlock = null;
        textBlock = null;
        coreBlock = null;
        ownedSourceName = null;
    }

    private void releaseAllocation(ref void[] block)
    {
        if (block.length)
            () @trusted { alloc.deallocate(block); }();
        block = null;
    }
}

/** Copyable borrowed view of one SDL node: its document's core and a cell
index, 16 bytes.

`dip1000` tracks every view, range, and payload slice back to the owning
document: a view cannot outlive the `SdlDocument` it was reached through.
*/
struct SdlNode
{
    private const(SdlCore)* _core;
    private size_t _cell;

    package this(return scope const(SdlCore)* core, size_t cell)
        @safe pure nothrow @nogc
    {
        _core = core;
        _cell = cell;
    }

    // A flat core's cell, read in place; the views' fast path.
    pragma(inline, true)
    private ref const(SdlNodeCell) flatCell() const return scope @trusted pure nothrow @nogc
        => _core.flatNodes[_cell];

    // A shared core's cell and its run (editing §10.1), out of line so the
    // flat path stays small. Narrow trust: the cell is the core's, which
    // outlives `scope this`.
    private const(SdlNodeCell)* sharedCell(out const(SdlRun)* run) const scope @trusted
        pure nothrow @nogc
        => _core.sharedNode(_cell, run);

    pragma(inline, false)
    private SdlSpan sharedSpan(string field)() const scope @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        return shiftedBy(__traits(getMember, sharedCell(run), field), run.delta);
    }

    pragma(inline, false)
    private auto sharedField(string field)() const scope @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        return __traits(getMember, sharedCell(run), field);
    }

    package const(SdlCore)* core() const return scope @safe pure nothrow @nogc
        => _core;
    package size_t cellIndex() const scope @safe pure nothrow @nogc => _cell;

    /// Full stored name. The synthetic root returns the empty/default name.
    pragma(inline, true)
    SdlQualifiedName qualifiedName() const return scope @safe pure nothrow @nogc
        => _core.flat ? (() @trusted => flatCell.qualifiedName)() : sharedName();

    pragma(inline, false)
    private SdlQualifiedName sharedName() const return scope @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        const cell = sharedCell(run);
        return (() @trusted => respelled(cell.qualifiedName,
            shiftedBy(cell.nameSpan, run.delta), _core.source))();
    }

    /// Exact qualified-name span, or the root's zero-width source-start span.
    pragma(inline, true)
    SdlSpan nameSpan() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.nameSpan : sharedSpan!"nameSpan";

    /// Complete declaration span, from the name through the terminator.
    pragma(inline, true)
    SdlSpan span() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.span : sharedSpan!"span";

    /** The bytes that belong to this node and to nothing else (editing §2):
    whole lines when it is alone on them, else the inline range; removing it
    leaves its neighbours intact. Invalid for an encoded document. */
    pragma(inline, true)
    SdlSpan extent() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.extent : sharedSpan!"extent";

    /// Whether no other node's tokens and no enclosing brace share its lines.
    pragma(inline, true)
    bool aloneOnLines() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.aloneOnLines : sharedField!"aloneOnLines";

    /// Number of positional scalar values.
    pragma(inline, true)
    size_t valueCount() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.valueCount : sharedField!"valueCount";
    /// Number of attributes, including duplicates.
    pragma(inline, true)
    size_t attributeCount() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.attributeCount : sharedField!"attributeCount";
    /// Number of direct children, including repeated names.
    pragma(inline, true)
    size_t childCount() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.childCount : sharedField!"childCount";
    /// Whether the source declaration carried a `{ }` block.
    pragma(inline, true)
    bool hasBlock() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.hasBlock : sharedField!"hasBlock";

    /// Positional value `index`, by index rather than by walking the range.
    package SdlScalar valueAt(size_t index) const return scope @safe pure nothrow @nogc
    in (index < valueCount, "no such value")
    {
        auto values = byValue;
        values._index = index;
        return values.front;
    }

    /// Forward range over positional values in source order.
    pragma(inline, true)
    SdlValueRange byValue() const return scope @safe pure nothrow @nogc
    {
        if (_core.flat)
        {
            const start = flatCell.valueStart;
            return (() @trusted => SdlValueRange(_core.flatValues[start
                .. start + flatCell.valueCount], 0))();
        }
        return sharedValues();
    }

    pragma(inline, false)
    private SdlValueRange sharedValues() const return scope @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        const cell = sharedCell(run);
        // Narrow trust: as for `sharedCell`; the values are in the same block.
        return (() @trusted => SdlValueRange(run.block.values[cell.valueStart
            .. cell.valueStart + cell.valueCount], run.delta))();
    }

    /// Forward range over every attribute in source order.
    pragma(inline, true)
    SdlAttributeRange byAttribute() const return scope @safe pure nothrow @nogc
    {
        size_t start, count;
        if (_core.flat)
        {
            start = flatCell.attributeStart;
            count = flatCell.attributeCount;
        }
        else
        {
            const(SdlRun)* run;
            const cell = sharedCell(run);
            start = run.attributeBase + (cell.attributeStart - run.attributeLo);
            count = cell.attributeCount;
        }
        return (() @trusted => SdlAttributeRange(_core, start, start + count))();
    }

    /// Every attribute matching an exact full qualified name.
    SdlFilteredAttributeRange byAttribute(return scope SdlQualifiedName name) const
        return scope @safe pure nothrow @nogc
        => byAttribute(SdlNameQuery(name));

    /// Every attribute matching `query`, retaining source order.
    SdlFilteredAttributeRange byAttribute(return scope SdlNameQuery query) const
        return scope @safe pure nothrow @nogc
        => SdlFilteredAttributeRange(byAttribute, query);

    /// Forward range over direct children in source order.
    pragma(inline, true)
    SdlChildRange byChild() const return scope @safe pure nothrow @nogc
        => (() @trusted => SdlChildRange(_core, _cell + 1, childCount))();

    /// Every direct child matching an exact full qualified name.
    SdlFilteredChildRange byChild(return scope SdlQualifiedName name) const
        return scope @safe pure nothrow @nogc
        => byChild(SdlNameQuery(name));

    /// Every direct child matching `query`, retaining source order.
    SdlFilteredChildRange byChild(return scope SdlNameQuery query) const
        return scope @safe pure nothrow @nogc
        => SdlFilteredChildRange(byChild, query);
}

/// Borrowed attribute occurrence: its document's core and a cell index.
struct SdlAttributeView
{
    private const(SdlCore)* _core;
    private size_t _cell;

    package this(return scope const(SdlCore)* core, size_t cell)
        @safe pure nothrow @nogc
    {
        _core = core;
        _cell = cell;
    }

    // As for `SdlNode`: a flat core's cell in place, a shared one's out of line.
    pragma(inline, true)
    private ref const(SdlAttributeCell) flatCell() const return scope @trusted
        pure nothrow @nogc
        => _core.flatAttributes[_cell];

    // Narrow trust: as for `SdlNode.sharedCell`.
    private const(SdlAttributeCell)* sharedCell(out const(SdlRun)* run) const scope @trusted
        pure nothrow @nogc
        => _core.sharedAttribute(_cell, run);

    pragma(inline, false)
    private SdlSpan sharedSpan(string field)() const scope @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        return shiftedBy(__traits(getMember, sharedCell(run), field), run.delta);
    }

    package const(SdlCore)* core() const return scope @safe pure nothrow @nogc
        => _core;
    package size_t cellIndex() const scope @safe pure nothrow @nogc => _cell;

    /// Full stored attribute name.
    pragma(inline, true)
    SdlQualifiedName qualifiedName() const return scope @safe pure nothrow @nogc
        => _core.flat ? (() @trusted => flatCell.qualifiedName)() : sharedName();

    pragma(inline, false)
    private SdlQualifiedName sharedName() const return scope @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        const cell = sharedCell(run);
        return (() @trusted => respelled(cell.qualifiedName,
            shiftedBy(cell.nameSpan, run.delta), _core.source))();
    }

    /// Exact qualified-name source span.
    pragma(inline, true)
    SdlSpan nameSpan() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.nameSpan : sharedSpan!"nameSpan";
    /// Span from name start through scalar end.
    pragma(inline, true)
    SdlSpan span() const scope @safe pure nothrow @nogc
        => _core.flat ? flatCell.span : sharedSpan!"span";
    /// Borrowed scalar value and its exact token span.
    pragma(inline, true)
    SdlScalar value() const return scope @safe pure nothrow @nogc
        => _core.flat ? (() @trusted => flatCell.value)() : sharedValue();

    pragma(inline, false)
    private SdlScalar sharedValue() const return scope @safe pure nothrow @nogc
    {
        const(SdlRun)* run;
        SdlScalar scalar = (() @trusted => sharedCell(run).value)();
        scalar.shiftSpan(run.delta);
        return scalar;
    }
}

/// Forward range over scalar values.
struct SdlValueRange
{
    private const(SdlValueCell)[] _cells;
    private uint _delta;
    private size_t _index;
    private this(return scope const(SdlValueCell)[] cells, uint delta)
        @safe pure nothrow @nogc
    {
        _cells = cells;
        _delta = delta;
    }
    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _index >= _cells.length;
    /// ditto
    pragma(inline, true)
    SdlScalar front() const return scope @safe pure nothrow @nogc
    in (!empty)
    {
        SdlScalar scalar = (() @trusted => _cells[_index].value)();
        scalar.shiftSpan(_delta);
        return scalar;
    }
    /// ditto
    pragma(inline, true)
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    /// ditto
    SdlValueRange save() const return scope @safe pure nothrow @nogc => this;
}

/// Forward range over attributes.
struct SdlAttributeRange
{
    private const(SdlCore)* _core;
    private size_t _index;
    private size_t _end;
    private this(return scope const(SdlCore)* core, size_t start, size_t end)
        @safe pure nothrow @nogc
    {
        _core = core;
        _index = start;
        _end = end;
    }
    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _index >= _end;
    /// ditto
    pragma(inline, true)
    SdlAttributeView front() const return scope @safe pure nothrow @nogc
    in (!empty) => SdlAttributeView(_core, _index);
    /// ditto
    pragma(inline, true)
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    /// ditto
    SdlAttributeRange save() const return scope @safe pure nothrow @nogc => this;
}

/// Forward range over direct child nodes.
///
/// Iteration steps from the first child, which follows its parent, over each
/// child's subtree to the next; every yielded view refers to the whole
/// document's core.
struct SdlChildRange
{
    private const(SdlCore)* _core;
    private size_t _next;
    private size_t _remaining;
    private this(return scope const(SdlCore)* core, size_t first, size_t count)
        @safe pure nothrow @nogc
    {
        _core = core;
        _next = first;
        _remaining = count;
    }
    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _remaining == 0;
    /// ditto
    pragma(inline, true)
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => SdlNode(_core, _next);
    /// ditto
    pragma(inline, true)
    void popFront() scope @safe pure nothrow @nogc
    in (!empty)
    {
        _next += _core.subtreeSizeAt(_next);
        _remaining--;
    }
    /// ditto
    SdlChildRange save() const return scope @safe pure nothrow @nogc => this;
}

/// Random-access range over a document's comments, in source order (editing
/// SDE6).
struct SdlCommentRange
{
    private const(SdlCore)* _core;
    private size_t _index;
    private size_t _end;
    private this(return scope const(SdlCore)* core, size_t start, size_t end)
        @safe pure nothrow @nogc
    {
        _core = core;
        _index = start;
        _end = end;
    }
    /// Random-access-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _index >= _end;
    /// ditto
    size_t length() const scope @safe pure nothrow @nogc => _end - _index;
    /// ditto
    alias opDollar = length;
    /// ditto
    SdlComment front() const scope @safe pure nothrow @nogc
    in (!empty) => _core.commentAt(_index);
    /// ditto
    SdlComment back() const scope @safe pure nothrow @nogc
    in (!empty) => _core.commentAt(_end - 1);
    /// ditto
    SdlComment opIndex(size_t i) const scope @safe pure nothrow @nogc
    in (i < length) => _core.commentAt(_index + i);
    /// ditto
    pragma(inline, true)
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    /// ditto
    void popBack() scope @safe pure nothrow @nogc
    in (!empty) { _end--; }
    /// ditto
    SdlCommentRange save() const return scope @safe pure nothrow @nogc => this;
    /// The comments `[from, to)` of this range.
    SdlCommentRange opSlice(size_t from, size_t to) const return scope @safe pure nothrow @nogc
    in (from <= to && to <= length)
        => SdlCommentRange(_core, _index + from, _index + to);
}

/// Qualified-name-filtered attribute range preserving every match.
struct SdlFilteredAttributeRange
{
    private SdlAttributeRange source;
    private SdlNameQuery query;
    /// Positions the range on the first member matching `query`.
    this(return scope SdlAttributeRange source, return scope SdlNameQuery query)
        @safe pure nothrow @nogc
    {
        this.source = source;
        this.query = query;
        skip();
    }
    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => source.empty;
    /// ditto
    pragma(inline, true)
    SdlAttributeView front() const return scope @safe pure nothrow @nogc
    in (!empty) => source.front;
    /// ditto
    pragma(inline, true)
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { source.popFront(); skip(); }
    /// ditto
    SdlFilteredAttributeRange save() const return scope @safe pure nothrow @nogc
        => this;
    private void skip() scope @safe pure nothrow @nogc
    {
        while (!source.empty && !query.matches(source.front.qualifiedName))
            source.popFront();
    }
}

/// Qualified-name-filtered child range preserving every match.
struct SdlFilteredChildRange
{
    private SdlChildRange source;
    private SdlNameQuery query;
    /// Positions the range on the first member matching `query`.
    this(return scope SdlChildRange source, return scope SdlNameQuery query)
        @safe pure nothrow @nogc
    {
        this.source = source;
        this.query = query;
        skip();
    }
    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => source.empty;
    /// ditto
    pragma(inline, true)
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => source.front;
    /// ditto
    pragma(inline, true)
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { source.popFront(); skip(); }
    /// ditto
    SdlFilteredChildRange save() const return scope @safe pure nothrow @nogc
        => this;
    private void skip() scope @safe pure nothrow @nogc
    {
        while (!source.empty && !query.matches(source.front.qualifiedName))
            source.popFront();
    }
}


// ── Unknown-member capture (SPEC §8) ─────────────────────────────────────────

/** The SDL channel an unknown occurrence was captured from (SPEC §8). */
enum SdlExtraChannel : ubyte
{
    value,      /// a positional value beyond the declared slots
    attribute,  /// an attribute matching no declared qualified name
    child,      /// a child tag matching no declared child field name
}

/** One captured unknown occurrence (SPEC §8).

This is the *borrowed* member flavor: the name, scalar payload, and child view
alias the source document's arena, so a member is valid only while that
document lives (`-preview=dip1000` tracks the accessor chain exactly as it
tracks $(LREF SdlNode)). Payloads are exposed through `return scope` accessors
rather than public fields so escaping slices fail to compile at the document
boundary. The owning counterpart is $(LREF SdlOwnedExtraMember).
*/
struct SdlExtraMember
{
    private SdlExtraChannel _channel;
    private size_t _ordinal;
    private SdlQualifiedName _name;
    private SdlScalar _scalar;
    private SdlNode _node;
    private SdlSpan _span;

    package this(return scope SdlExtraChannel channel, size_t ordinal,
        return scope SdlQualifiedName name, return scope SdlScalar scalar,
        return scope SdlNode node, return scope SdlSpan span)
        @safe pure nothrow @nogc
    {
        _channel = channel;
        _ordinal = ordinal;
        _name = name;
        _scalar = scalar;
        _node = node;
        _span = span;
    }

    /// The channel this occurrence came from.
    SdlExtraChannel channel() const scope @safe pure nothrow @nogc => _channel;

    /// Index of this occurrence within its channel among ALL occurrences of
    /// the containing tag — the encode-time merge position.
    size_t ordinal() const scope @safe pure nothrow @nogc => _ordinal;

    /// Borrowed qualified name; both halves empty for `value` members.
    SdlQualifiedName name() const return scope @safe pure nothrow @nogc
        => (() @trusted => _name)();

    /// Borrowed scalar payload; kind $(LREF SdlScalarKind.none) for `child`
    /// members.
    SdlScalar scalar() const return scope @safe pure nothrow @nogc
        => (() @trusted => _scalar)();

    /// Borrowed child-subtree view; invalid for the other channels.
    SdlNode node() const return scope @safe pure nothrow @nogc
        => (() @trusted => _node)();

    /// Source span of the occurrence: the scalar token for values, the whole
    /// `name=value` extent for attributes, the full declaration for children.
    SdlSpan span() const scope @safe pure nothrow @nogc => _span;
}

/** Ordered unmatched-occurrence capture — the borrowed flavor (SPEC §8).

Members appear in canonical grammar order: all captured positional values by
position, then attributes in occurrence order, then children in occurrence
order. The type is valid only while its source document lives; decode refuses
it from the text convenience overload at compile time. Use
$(LREF OwnedSdlExtras) when the capture must outlive the document.
*/
struct SdlExtras
{
    /// Opaque to the shared wire schema (SPEC §1.1 seam): only the SDL
    /// backend interprets captured occurrences.
    static enum bool wirePassthrough = true;

    private SdlExtraMember[] _members;

    package this(return scope SdlExtraMember[] members) @safe pure nothrow @nogc
    {
        _members = members;
    }

    /// Number of captured occurrences.
    size_t length() const scope @safe pure nothrow @nogc => _members.length;

    /// Whether nothing was captured.
    bool empty() const scope @safe pure nothrow @nogc => _members.length == 0;

    /// Borrowed view of member `i` in storage order.
    SdlExtraMember at(size_t i) const return scope @safe pure nothrow @nogc
    in (i < _members.length)
        => (() @trusted => _members[i])();
}

/// One owned attribute occurrence inside an $(LREF SdlOwnedExtraNode) subtree.
struct SdlOwnedExtraAttribute
{
    SdlQualifiedName name;  /// owned-spelling qualified name
    SdlScalar value;        /// scalar whose string/binary/zone payloads are pooled
}

/** Owned recursive capture of one unknown child subtree (SPEC §8).

Mirrors the semantic shape of an SDL node: ordered values, ordered attributes
(with duplicates), and ordered children. Every slice-bearing payload is copied
into the owner's pools, so the tree survives its source document. `hasBlock`
keeps the source's `{ }` presence so canonical re-emission stays byte-stable
for empty blocks.
*/
struct SdlOwnedExtraNode
{
    SdlQualifiedName name;              /// owned-spelling qualified name
    SdlScalar[] values;                 /// pooled payloads, source order
    SdlOwnedExtraAttribute[] attributes; /// pooled entries, source order
    SdlOwnedExtraNode[] children;       /// recursive captures, source order
    bool hasBlock;                      /// source declaration carried `{ }`
}

/** One captured unknown occurrence — the owned flavor (SPEC §8).

Same metadata as $(LREF SdlExtraMember), but every payload is deep-copied:
value/attribute scalars pool their string/binary/zone bytes, and `child`
members materialize the whole subtree as an $(LREF SdlOwnedExtraNode). The
simplest design that survives typed decode→encode→decode byte-stably without
keeping allocator bookkeeping alive alongside the value.
*/
struct SdlOwnedExtraMember
{
    SdlExtraChannel channel;    /// the channel this occurrence came from
    size_t ordinal;             /// index within its channel (see SdlExtraMember)
    SdlQualifiedName name;      /// owned spelling; empty for `value` members
    SdlScalar scalar;           /// pooled payload; `.none` kind for children
    SdlOwnedExtraNode node;     /// owned subtree; default-empty otherwise
    SdlSpan span;               /// recorded source coordinates of the original
}

/** Ordered unmatched-occurrence capture — the owning flavor (SPEC §8).

Usable after the input buffer and source document are gone; works with both
$(LREF fromSDL) overloads. Members follow the same canonical order as
$(LREF SdlExtras).
*/
struct OwnedSdlExtras
{
    /// Opaque to the shared wire schema (SPEC §1.1 seam): only the SDL
    /// backend interprets captured occurrences.
    static enum bool wirePassthrough = true;

    SdlOwnedExtraMember[] members; /// captured occurrences, canonical order

    package char[][] _strings;   /// owns copied UTF-8 payloads and names
    package ubyte[][] _binaries; /// owns copied binary payloads

    /// Number of captured occurrences.
    size_t length() const scope @safe pure nothrow @nogc => members.length;

    /// Whether nothing was captured.
    bool empty() const scope @safe pure nothrow @nogc => members.length == 0;

    /// Member `i` in storage order.
    ref inout(SdlOwnedExtraMember) at(size_t i) inout return scope
        @safe pure nothrow @nogc
    in (i < members.length)
        => members[i];
}

package char[] poolSlice(scope const(char)[] s, ref char[][] strings)
    @safe pure
{
    if (s.length == 0)
        return null;
    strings ~= s.dup;
    return strings[$ - 1];
}

package SdlQualifiedName poolName(return scope SdlQualifiedName n,
    ref char[][] strings) @safe pure
=> SdlQualifiedName(poolSlice(n.namespace_, strings),
    poolSlice(n.localName, strings));

/** Deep-copies `s`'s slice-bearing payloads into the given pools, preserving
the exact scalar kind (string bytes, binary bytes, and zoned zone spellings
are the only slice-bearing payloads). */
package SdlScalar poolScalar(return scope SdlScalar s, ref char[][] strings,
    ref ubyte[][] binaries) @safe pure
{
    final switch (s.kind) with (SdlScalarKind)
    {
    case none:
    case null_:
    case boolean:
    case character:
    case integer:
    case longInteger:
    case float_:
    case double_:
    case decimal:
    case date:
    case dateTime:
    case duration:
        return s;
    case string_:
        return SdlScalar(poolSlice(s.stringValue, strings));
    case binary:
    {
        const raw = s.binary;
        if (raw.length == 0)
            return SdlScalar(cast(const(ubyte)[]) null);
        binaries ~= cast(ubyte[]) raw.dup;
        return SdlScalar(binaries[$ - 1]);
    }
    case zonedDateTime:
    {
        const zoned = s.zonedDateTime;
        return SdlScalar(SdlZonedDateTime(zoned.local,
            poolSlice(zoned.zone, strings), zoned.utcOffset,
            zoned.hasUtcOffset));
    }
    }
}

@("sdl.document.scalarKindsAndPayloads")
@safe pure nothrow @nogc
unittest
{
    import core.time : seconds;

    assert(SdlScalar(null).kind == SdlScalarKind.null_);
    assert(SdlScalar(true).boolean);
    assert(SdlScalar("text").stringValue == "text");
    assert(SdlScalar(cast(dchar) 'x').character == 'x');
    assert(SdlScalar(int.min).integer == int.min);
    assert(SdlScalar(long.max).longInteger == long.max);
    assert(SdlScalar(1.25f).floatValue == 1.25f);
    assert(SdlScalar(2.5).doubleValue == 2.5);
    assert(SdlScalar.decimal(3.75L).decimalValue == 3.75L);
    static immutable ubyte[3] bytes = [0, 1, 2];
    assert(SdlScalar(bytes[]).binary == bytes[]);
    assert(SdlScalar(5.seconds).duration == 5.seconds);
}

@("sdl.document.sourceVocabulary")
@safe pure nothrow @nogc
unittest
{
    auto name = SdlQualifiedName("x", "platform");
    assert(name.namespace_ == "x" && name.localName == "platform");

    auto span = SdlSpan(3, 7);
    assert(span.startOffset == 3 && span.endOffset == 7 && span.length == 4);
    assert(span.sliceOf("abcdefgh") == "defg");
    assert(!SdlSpan.init.isValid && SdlSpan.at(2).length == 0);
}

@("sdl.document.textPayloadsAreConstBorrowed")
@safe pure nothrow @nogc
unittest
{
    char[4] text = "text";
    auto scalar = SdlScalar(text[]);
    assert(scalar.stringValue == "text");
    static assert(!__traits(compiles, scalar.stringValue[0] = 'T'));

    text[0] = 'T';
    assert(scalar.stringValue == "Text");

    auto name = SdlQualifiedName(text[0 .. 1], text[1 .. $]);
    auto zoned = SdlZonedDateTime(zone: text[]);
    static assert(!__traits(compiles, name.localName[0] = 'x'));
    static assert(!__traits(compiles, zoned.zone[0] = 'x'));
}

@("sdl.document.extras.borrowedMemberAccessors")
@safe pure nothrow @nogc
unittest
{
    SdlExtraMember member = SdlExtraMember(SdlExtraChannel.attribute, 3,
        SdlQualifiedName("x", "platform"), SdlScalar(7),
        SdlNode.init, SdlSpan(1, 9));

    assert(member.channel == SdlExtraChannel.attribute);
    assert(member.ordinal == 3);
    assert(member.name.namespace_ == "x" && member.name.localName == "platform");
    assert(member.scalar.kind == SdlScalarKind.integer);
    assert(member.span.startOffset == 1);

    SdlExtraMember[1] storage = [member];
    auto extras = SdlExtras(storage[]);
    assert(extras.length == 1 && !extras.empty);
    assert(extras.at(0).ordinal == 3);

    assert(SdlExtras.init.empty && SdlExtras.init.length == 0);
}

@("sdl.document.extras.ownedPoolingCopiesEverySlice")
@safe pure unittest
{
    import core.time : seconds;

    // Narrow trust: untracks one scalar copy for heap stashing in this
    // pooling test only (the pool owns the bytes afterwards).
    static SdlScalar borrowAny(scope const ref SdlScalar s) @safe
        => (() @trusted { const ps = &s; return *ps; })();

    static SdlQualifiedName borrowName(scope const ref SdlQualifiedName n) @safe
        => (() @trusted { const pn = &n; return *pn; })();

    OwnedSdlExtras owned;
    char[][] strings;
    ubyte[][] binaries;

    // String payloads are copied, not aliased.
    char[6] text = "origin";
    const rawText = SdlScalar(text[]);
    const pooledText = poolScalar(borrowAny(rawText), strings, binaries);
    owned.members ~= SdlOwnedExtraMember(SdlExtraChannel.value, 0,
        SdlQualifiedName.init, borrowAny(pooledText),
        SdlOwnedExtraNode.init, SdlSpan.init);
    text[] = 'X';
    assert(owned.at(0).scalar.stringValue == "origin");

    // Binary and zone spellings likewise.
    immutable ubyte[3] bytes = [9, 8, 7];
    const rawBytes = SdlScalar(bytes[]);
    const pooledBytes = poolScalar(borrowAny(rawBytes), strings, binaries);
    const pooledName = poolName(SdlQualifiedName("ns", "blob"), strings);
    owned.members ~= SdlOwnedExtraMember(SdlExtraChannel.attribute, 1,
        borrowName(pooledName), borrowAny(pooledBytes),
        SdlOwnedExtraNode.init, SdlSpan.init);
    assert(owned.at(1).name.localName == "blob");
    assert(owned.at(1).scalar.binary == bytes[]);

    const zoneSource = "Planet/Earth";
    const rawZone = SdlScalar(SdlZonedDateTime(SdlDateTime(Date(2024, 1, 2),
        3, 4, 5, 0), zoneSource, 0.seconds, false));
    auto pooledZone = poolScalar(borrowAny(rawZone), strings, binaries);
    owned.members[1] = SdlOwnedExtraMember(SdlExtraChannel.attribute, 1,
        owned.at(1).name, borrowAny(pooledZone),
        SdlOwnedExtraNode.init, SdlSpan.init);
    assert(owned.at(1).scalar.zonedDateTime.zone == zoneSource);

    assert(owned.length == 2);
    assert(strings.length >= 3 && binaries.length == 1);
}
