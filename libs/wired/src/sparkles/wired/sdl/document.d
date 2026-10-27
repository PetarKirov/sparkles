/** SDL semantic values and the owning ordered arena document. */
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
    size_t childStart;
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

/** A document's immovable core: its cells, owned source, line table and
layout (performance SDP3).

It lives in one heap block the document points at, so moving a document never
invalidates a view, and its type does not depend on the allocator, so a view
can reach the source and line table without being a template.
*/
package struct SdlCore
{
    SdlNodeCell[] nodes;
    SdlValueCell[] values;
    SdlAttributeCell[] attributes;
    size_t[] childIndexes;
    SdlComment[] comments;
    /// The owned copy of the parsed text; `null` for an encoded document.
    const(char)[] source;
    /// The bytes nodes may occupy: the source after any byte-order mark,
    /// or an embedded recipe's text.
    SdlSpan content;
    /// Logical line starts; line 0 starts after any byte-order mark.
    LineIndex lines;

    /// The position of byte `offset` (at most the source length).
    SdlPosition position(size_t offset) const scope @safe pure nothrow @nogc
    {
        if (source.length == 0 || offset <= lines.lineStart(0))
            return SdlPosition(offset, 1, 1);
        const at = offset > source.length ? source.length : offset;
        const lc = lines.lineColAt(at, source);
        return SdlPosition(offset, cast(uint)(lc.line + 1), cast(uint)(lc.column + 1));
    }
}

/** Owning, movable, non-copyable parsed SDL document.

The document owns a copy of the text it was parsed from (`source`), and every
span is a byte range into that copy; `position` turns an offset into a line and
column. The synthetic root always has the empty/default qualified name and a
zero-width span at the source start after UTF-8 BOM handling.
*/
struct SdlDocument(Allocator = Mallocator)
{
    static if (stateSize!Allocator)
        package Allocator alloc;
    else
        package alias alloc = Allocator.instance;

    package SdlCore* core;
    package ubyte[] pool;
    private void[] coreBlock;
    private void[] nodeBlock;
    private void[] valueBlock;
    private void[] attributeBlock;
    private void[] childBlock;
    private void[] commentBlock;
    private void[] poolBlock;
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
        swap(coreBlock, rhs.coreBlock);
        swap(nodeBlock, rhs.nodeBlock);
        swap(valueBlock, rhs.valueBlock);
        swap(attributeBlock, rhs.attributeBlock);
        swap(childBlock, rhs.childBlock);
        swap(commentBlock, rhs.commentBlock);
        swap(poolBlock, rhs.poolBlock);
        swap(ownedSourceName, rhs.ownedSourceName);
    }

    /// Whether this document contains its synthetic root.
    bool valid() const scope @safe pure nothrow @nogc
        => core !is null && core.nodes.length != 0;

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

    /// The owned copy of the parsed text, which every span indexes.
    const(char)[] source() const return scope @safe pure nothrow @nogc
        => core is null ? null : (() @trusted => core.source)();

    /** The line and column of byte `offset` of `source`.

    Line 1 starts after any byte-order mark; each logical newline (`\n`, `\r`,
    `\r\n`, U+2028, U+2029) starts a line; columns count one per UTF-8 sequence
    and one per invalid byte. */
    SdlPosition position(size_t offset) const scope @safe pure nothrow @nogc
        => core is null ? SdlPosition(offset) : core.position(offset);

    /// Every comment in the source, in source order (editing SDE6).
    const(SdlComment)[] comments() const return scope @safe pure nothrow @nogc
        => core is null ? null : (() @trusted => core.comments)();

    ~this()
    {
        release();
    }

    /** Allocates the core, the pool, and first capacities for the node,
    value and attribute arrays; the parser grows those (`grow`) and trims
    them (`finish`). */
    package bool acquire(size_t nodeCapacity, size_t valueCapacity,
        size_t attributeCapacity, size_t poolBytes)
    {
        SdlCore[] coreSlot;
        if (!acquireBlock(coreSlot, coreBlock, 1))
            return false;
        () @trusted {
            import core.lifetime : emplace;

            emplace(&coreSlot[0]);
            core = &coreSlot[0];
        }();
        if (!acquireBlock(pool, poolBlock, poolBytes)
            || !acquireBlock(core.nodes, nodeBlock, nodeCapacity)
            || !acquireBlock(core.values, valueBlock, valueCapacity)
            || !acquireBlock(core.attributes, attributeBlock, attributeCapacity))
        {
            release();
            return false;
        }
        return true;
    }

    /// Doubles `field`'s array, keeping its first `used` cells.
    package bool grow(string field)(size_t used)
    {
        static if (field == "nodes")
            alias block = nodeBlock;
        else static if (field == "values")
            alias block = valueBlock;
        else
            alias block = attributeBlock;
        alias T = typeof(__traits(getMember, *core, field)[0]);

        const capacity = __traits(getMember, *core, field).length;
        const wanted = capacity < 8 ? 16 : capacity * 2;
        T[] grown;
        void[] grownBlock;
        if (wanted <= capacity || !acquireBlock(grown, grownBlock, wanted))
            return false;
        grown[0 .. used] = __traits(getMember, *core, field)[0 .. used];
        releaseBlock(block);
        block = grownBlock;
        __traits(getMember, *core, field) = grown;
        return true;
    }

    /** Trims the grown arrays to the cells the parser filled, and allocates
    the child-index arena (one entry per node below the root) and the exact
    comment array. */
    package bool finish(size_t nodeCount, size_t valueCount, size_t attributeCount,
        scope const(SdlComment)[] comments)
    {
        core.nodes = core.nodes[0 .. nodeCount];
        core.values = core.values[0 .. valueCount];
        core.attributes = core.attributes[0 .. attributeCount];
        if (!acquireBlock(core.childIndexes, childBlock, nodeCount - 1)
            || !acquireBlock(core.comments, commentBlock, comments.length))
            return false;
        core.comments[] = comments[];
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

    private void release()
    {
        if (core !is null)
            () @trusted { destroy(core.lines); }();
        static if (__traits(hasMember, Allocator, "deallocate"))
        {
            releaseBlock(coreBlock);
            releaseBlock(nodeBlock);
            releaseBlock(valueBlock);
            releaseBlock(attributeBlock);
            releaseBlock(childBlock);
            releaseBlock(commentBlock);
            releaseBlock(poolBlock);
        }
        core = null;
        pool = null;
        coreBlock = null;
        nodeBlock = null;
        valueBlock = null;
        attributeBlock = null;
        childBlock = null;
        commentBlock = null;
        poolBlock = null;
        ownedSourceName = null;
    }

    private void releaseBlock(ref void[] block)
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

    // Narrow trust: the cell copy outlives `scope this` only as a value.
    private SdlNodeCell cell() const scope @safe pure nothrow @nogc
        => (() @trusted => _core.nodes[_cell])();

    package const(SdlCore)* core() const return scope @safe pure nothrow @nogc
        => _core;
    package size_t cellIndex() const scope @safe pure nothrow @nogc => _cell;

    /// Full stored name. The synthetic root returns the empty/default name.
    SdlQualifiedName qualifiedName() const return scope @safe pure nothrow @nogc
        => (() @trusted => _core.nodes[_cell].qualifiedName)();

    /// Exact qualified-name span, or the root's zero-width source-start span.
    SdlSpan nameSpan() const scope @safe pure nothrow @nogc => this.cell.nameSpan;

    /// Complete declaration span, from the name through the terminator.
    SdlSpan span() const scope @safe pure nothrow @nogc => this.cell.span;

    /** The bytes that belong to this node and to nothing else (editing §2):
    whole lines when it is alone on them, else the inline range; removing it
    leaves its neighbours intact. Invalid for an encoded document. */
    SdlSpan extent() const scope @safe pure nothrow @nogc => this.cell.extent;

    /// Whether no other node's tokens and no enclosing brace share its lines.
    bool aloneOnLines() const scope @safe pure nothrow @nogc
        => this.cell.aloneOnLines;

    /// Number of positional scalar values.
    size_t valueCount() const scope @safe pure nothrow @nogc => this.cell.valueCount;
    /// Number of attributes, including duplicates.
    size_t attributeCount() const scope @safe pure nothrow @nogc
        => this.cell.attributeCount;
    /// Number of direct children, including repeated names.
    size_t childCount() const scope @safe pure nothrow @nogc
        => this.cell.childCount;
    /// Whether the source declaration carried a `{ }` block.
    bool hasBlock() const scope @safe pure nothrow @nogc
        => this.cell.hasBlock;

    /// Forward range over positional values in source order.
    SdlValueRange byValue() const return scope @safe pure nothrow @nogc
    {
        const owned = this.cell;
        return (() @trusted => SdlValueRange(_core.values[owned.valueStart
            .. owned.valueStart + owned.valueCount]))();
    }

    /// Forward range over every attribute in source order.
    SdlAttributeRange byAttribute() const return scope @safe pure nothrow @nogc
    {
        const owned = this.cell;
        return (() @trusted => SdlAttributeRange(_core, owned.attributeStart,
            owned.attributeStart + owned.attributeCount))();
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
    SdlChildRange byChild() const return scope @safe pure nothrow @nogc
    {
        const owned = this.cell;
        return (() @trusted => SdlChildRange(_core, _core.childIndexes[owned.childStart
            .. owned.childStart + owned.childCount]))();
    }

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

    // Narrow trust: as for `SdlNode.cell`.
    private SdlAttributeCell cell() const scope @safe pure nothrow @nogc
        => (() @trusted => _core.attributes[_cell])();

    package const(SdlCore)* core() const return scope @safe pure nothrow @nogc
        => _core;
    package size_t cellIndex() const scope @safe pure nothrow @nogc => _cell;

    /// Full stored attribute name.
    SdlQualifiedName qualifiedName() const return scope @safe pure nothrow @nogc
        => (() @trusted => _core.attributes[_cell].qualifiedName)();
    /// Exact qualified-name source span.
    SdlSpan nameSpan() const scope @safe pure nothrow @nogc => this.cell.nameSpan;
    /// Span from name start through scalar end.
    SdlSpan span() const scope @safe pure nothrow @nogc => this.cell.span;
    /// Borrowed scalar value and its exact token span.
    SdlScalar value() const return scope @safe pure nothrow @nogc
        => (() @trusted => _core.attributes[_cell].value)();
}

/// Forward range over scalar values.
struct SdlValueRange
{
    private const(SdlValueCell)[] _cells;
    private size_t _index;
    private this(return scope const(SdlValueCell)[] cells)
        @safe pure nothrow @nogc
    {
        _cells = cells;
    }
    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _index >= _cells.length;
    /// ditto
    SdlScalar front() const return scope @safe pure nothrow @nogc
    in (!empty) => (() @trusted => _cells[_index].value)();
    /// ditto
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
    SdlAttributeView front() const return scope @safe pure nothrow @nogc
    in (!empty) => SdlAttributeView(_core, _index);
    /// ditto
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    /// ditto
    SdlAttributeRange save() const return scope @safe pure nothrow @nogc => this;
}

/// Forward range over direct child nodes.
///
/// Iteration walks the parent's contiguous index window; every yielded
/// view refers to the whole document's core.
struct SdlChildRange
{
    private const(SdlCore)* _core;
    private const(size_t)[] _window;
    private size_t _index;
    private this(return scope const(SdlCore)* core,
        return scope const(size_t)[] window) @safe pure nothrow @nogc
    {
        _core = core;
        _window = window;
    }
    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _index >= _window.length;
    /// ditto
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => (() @trusted => SdlNode(_core, _window[_index]))();
    /// ditto
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    /// ditto
    SdlChildRange save() const return scope @safe pure nothrow @nogc => this;
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
    SdlAttributeView front() const return scope @safe pure nothrow @nogc
    in (!empty) => source.front;
    /// ditto
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
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => source.front;
    /// ditto
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
