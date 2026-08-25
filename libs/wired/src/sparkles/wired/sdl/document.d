/** SDL semantic values and the owning ordered arena document. */
module sparkles.wired.sdl.document;

import core.time : Duration;
import std.datetime.date : Date;
import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;

/// Exact semantic kind retained for every SDL scalar.
enum SdlScalarKind : ubyte
{
    none,
    null_,
    boolean,
    string_,
    character,
    integer,
    longInteger,
    float_,
    double_,
    decimal,
    binary,
    date,
    dateTime,
    zonedDateTime,
    duration,
}

/// A namespace plus local name. An empty namespace is an ordinary SDL name.
struct SdlQualifiedName
{
    const(char)[] namespace_;
    const(char)[] localName;

    /// Full identity equality; namespaces are never implicit wildcards.
    bool opEquals(scope const SdlQualifiedName rhs) const scope
        @safe pure nothrow @nogc
        => namespace_ == rhs.namespace_ && localName == rhs.localName;
}

/// Namespace matching policy for a qualified-name query.
enum SdlNamespaceMatch : ubyte
{
    exact,
    wildcard,
}

/** A lookup-only qualified-name query.

`wildcard` matches every namespace for `name.localName`. It is deliberately a
query option and cannot be stored as an SDL qualified name.
*/
struct SdlNameQuery
{
    SdlQualifiedName name;
    SdlNamespaceMatch namespaceMatch;

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

/// One source position: zero-based byte offset and one-based display position.
struct SdlPosition
{
    size_t byteOffset;
    uint line = 1;
    uint column = 1;
}

/// Half-open source range.
struct SdlSpan
{
    SdlPosition start;
    SdlPosition end;
}

/** A local civil date-time with exact hectonanosecond fractional precision.

`fractionHnsecs` is the nonnegative fraction after `second` and must be below
10,000,000. The parser additionally constrains date-time literals to their
specified 1-3 decimal digits.
*/
struct SdlDateTime
{
    Date date;
    ubyte hour;
    ubyte minute;
    ubyte second;
    uint fractionHnsecs;
}

/** A local SDL date-time plus its original zone spelling.

Named zones remain valid without a host time-zone database. When resolution is
possible, `utcOffset` carries the exact offset and `hasUtcOffset` distinguishes
it from `Duration.zero` as an unknown offset.
*/
struct SdlZonedDateTime
{
    SdlDateTime local;
    const(char)[] zone;
    Duration utcOffset;
    bool hasUtcOffset;
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

/** Owning, movable, non-copyable parsed SDL document.

The synthetic root always has the empty/default qualified name and a
zero-width span at the source start after UTF-8 BOM handling.
*/
struct SdlDocument(Allocator = Mallocator)
{
    static if (stateSize!Allocator)
        package Allocator alloc;
    else
        package alias alloc = Allocator.instance;

    package SdlNodeCell[] nodes;
    package SdlValueCell[] values;
    package SdlAttributeCell[] attributes;
    package size_t[] childIndexes;
    package ubyte[] pool;
    private void[] nodeBlock;
    private void[] valueBlock;
    private void[] attributeBlock;
    private void[] childBlock;
    private void[] poolBlock;
    package const(char)[] ownedSourceName;

    @disable this(this);

    /// Move assignment transfers every allocation and allocator state.
    void opAssign(SdlDocument rhs)
    {
        import std.algorithm.mutation : swap;

        static if (stateSize!Allocator)
            swap(alloc, rhs.alloc);
        swap(nodes, rhs.nodes);
        swap(values, rhs.values);
        swap(attributes, rhs.attributes);
        swap(childIndexes, rhs.childIndexes);
        swap(pool, rhs.pool);
        swap(nodeBlock, rhs.nodeBlock);
        swap(valueBlock, rhs.valueBlock);
        swap(attributeBlock, rhs.attributeBlock);
        swap(childBlock, rhs.childBlock);
        swap(poolBlock, rhs.poolBlock);
        swap(ownedSourceName, rhs.ownedSourceName);
    }

    /// Whether this document contains its synthetic root.
    bool valid() const @safe pure nothrow @nogc => nodes.length != 0;

    /// Borrowed synthetic root view.
    SdlNode root() return scope const @safe pure nothrow @nogc
    in (valid, "empty document has no root")
        => SdlNode(nodes[], values[], attributes[], childIndexes[], 0);

    /// Owned source label supplied to the parser.
    const(char)[] sourceName() const return scope @safe pure nothrow @nogc
        => ownedSourceName;

    ~this()
    {
        release();
    }

    package bool acquire(size_t nodeCount, size_t valueCount,
        size_t attributeCount, size_t childCount, size_t poolBytes)
    {
        if (!acquireBlock(nodes, nodeBlock, nodeCount)
            || !acquireBlock(values, valueBlock, valueCount)
            || !acquireBlock(attributes, attributeBlock, attributeCount)
            || !acquireBlock(childIndexes, childBlock, childCount)
            || !acquireBlock(pool, poolBlock, poolBytes))
        {
            release();
            return false;
        }
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
        static if (__traits(hasMember, Allocator, "deallocate"))
        {
            releaseBlock(nodeBlock);
            releaseBlock(valueBlock);
            releaseBlock(attributeBlock);
            releaseBlock(childBlock);
            releaseBlock(poolBlock);
        }
        nodes = null;
        values = null;
        attributes = null;
        childIndexes = null;
        pool = null;
        nodeBlock = null;
        valueBlock = null;
        attributeBlock = null;
        childBlock = null;
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

/** Copyable borrowed view of one SDL node.

Views store slices of the document's arenas, so `dip1000` tracks every view,
range, and payload slice back to the owning document: a view cannot outlive
the `SdlDocument` it was reached through.
*/
struct SdlNode
{
    private const(SdlNodeCell)[] _nodes;
    private const(SdlValueCell)[] _values;
    private const(SdlAttributeCell)[] _attributes;
    private const(size_t)[] _childIndexes;
    private size_t _cell;

    private this(return scope const(SdlNodeCell)[] nodes,
        return scope const(SdlValueCell)[] values,
        return scope const(SdlAttributeCell)[] attributes,
        return scope const(size_t)[] childIndexes, size_t cell)
        @safe pure nothrow @nogc
    {
        _nodes = nodes;
        _values = values;
        _attributes = attributes;
        _childIndexes = childIndexes;
        _cell = cell;
    }

    private SdlNodeCell cell() const scope @trusted pure nothrow @nogc
        => _nodes[_cell];

    /// Full stored name. The synthetic root returns the empty/default name.
    SdlQualifiedName qualifiedName() const return scope @safe pure nothrow @nogc
        => (() @trusted => _nodes[_cell].qualifiedName)();

    /// Exact qualified-name span, or the root's zero-width source-start span.
    SdlSpan nameSpan() const scope @safe pure nothrow @nogc => this.cell.nameSpan;

    /// Complete declaration span.
    SdlSpan span() const scope @safe pure nothrow @nogc => this.cell.span;

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
        => (() @trusted => _nodes[_cell].hasBlock)();

    /// Forward range over positional values in source order.
    SdlValueRange byValue() const return scope @safe pure nothrow @nogc
    {
        const owned = this.cell;
        return (() @trusted => SdlValueRange(_values[owned.valueStart
            .. owned.valueStart + owned.valueCount]))();
    }

    /// Forward range over every attribute in source order.
    SdlAttributeRange byAttribute() const return scope @safe pure nothrow @nogc
    {
        const owned = this.cell;
        return (() @trusted => SdlAttributeRange(
            _attributes[owned.attributeStart
                .. owned.attributeStart + owned.attributeCount]))();
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
        return (() @trusted => SdlChildRange(_nodes, _values, _attributes,
            _childIndexes, _childIndexes[owned.childStart
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

/// Borrowed attribute occurrence.
struct SdlAttributeView
{
    private const(SdlAttributeCell)[] _cells;
    private size_t _cell;

    private this(return scope const(SdlAttributeCell)[] cells, size_t cell)
        @safe pure nothrow @nogc
    {
        _cells = cells;
        _cell = cell;
    }

    private SdlAttributeCell cell() const scope @trusted pure nothrow @nogc
        => _cells[_cell];

    /// Full stored attribute name.
    SdlQualifiedName qualifiedName() const return scope @safe pure nothrow @nogc
        => (() @trusted => _cells[_cell].qualifiedName)();
    /// Exact qualified-name source span.
    SdlSpan nameSpan() const scope @safe pure nothrow @nogc => this.cell.nameSpan;
    /// Span from name start through scalar end.
    SdlSpan span() const scope @safe pure nothrow @nogc => this.cell.span;
    /// Borrowed scalar value and its exact token span.
    SdlScalar value() const return scope @safe pure nothrow @nogc => this.cell.value;
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
    bool empty() const scope @safe pure nothrow @nogc => _index >= _cells.length;
    SdlScalar front() const return scope @safe pure nothrow @nogc
    in (!empty) => (() @trusted => _cells[_index].value)();
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    SdlValueRange save() const return scope @safe pure nothrow @nogc => this;
}

/// Forward range over attributes.
struct SdlAttributeRange
{
    private const(SdlAttributeCell)[] _cells;
    private size_t _index;
    private this(return scope const(SdlAttributeCell)[] cells)
        @safe pure nothrow @nogc
    {
        _cells = cells;
    }
    bool empty() const scope @safe pure nothrow @nogc => _index >= _cells.length;
    SdlAttributeView front() const return scope @safe pure nothrow @nogc
    in (!empty) => SdlAttributeView(_cells, _index);
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    SdlAttributeRange save() const return scope @safe pure nothrow @nogc => this;
}

/// Forward range over direct child nodes.
///
/// Iteration walks the parent's contiguous index window; every yielded
/// view carries the full arena slices so deeper descendants keep whole-
/// document addressing.
struct SdlChildRange
{
    private const(SdlNodeCell)[] _nodes;
    private const(SdlValueCell)[] _values;
    private const(SdlAttributeCell)[] _attributes;
    private const(size_t)[] _allIndexes;
    private const(size_t)[] _window;
    private size_t _index;
    private this(return scope const(SdlNodeCell)[] nodes,
        return scope const(SdlValueCell)[] values,
        return scope const(SdlAttributeCell)[] attributes,
        return scope const(size_t)[] allIndexes,
        return scope const(size_t)[] window) @safe pure nothrow @nogc
    {
        _nodes = nodes;
        _values = values;
        _attributes = attributes;
        _allIndexes = allIndexes;
        _window = window;
    }
    bool empty() const scope @safe pure nothrow @nogc => _index >= _window.length;
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => (() @trusted => SdlNode(_nodes, _values, _attributes,
        _allIndexes, _window[_index]))();
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { _index++; }
    SdlChildRange save() const return scope @safe pure nothrow @nogc => this;
}

/// Qualified-name-filtered attribute range preserving every match.
struct SdlFilteredAttributeRange
{
    private SdlAttributeRange source;
    private SdlNameQuery query;
    this(return scope SdlAttributeRange source, return scope SdlNameQuery query)
        @safe pure nothrow @nogc
    {
        this.source = source;
        this.query = query;
        skip();
    }
    bool empty() const scope @safe pure nothrow @nogc => source.empty;
    SdlAttributeView front() const return scope @safe pure nothrow @nogc
    in (!empty) => source.front;
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { source.popFront(); skip(); }
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
    this(return scope SdlChildRange source, return scope SdlNameQuery query)
        @safe pure nothrow @nogc
    {
        this.source = source;
        this.query = query;
        skip();
    }
    bool empty() const scope @safe pure nothrow @nogc => source.empty;
    SdlNode front() const return scope @safe pure nothrow @nogc
    in (!empty) => source.front;
    void popFront() scope @safe pure nothrow @nogc
    in (!empty) { source.popFront(); skip(); }
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

    auto span = SdlSpan(SdlPosition(3, 2, 4), SdlPosition(7, 2, 8));
    assert(span.start.byteOffset == 3 && span.end.column == 8);
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
        SdlNode.init, SdlSpan(SdlPosition(1, 1, 2), SdlPosition(9, 1, 10)));

    assert(member.channel == SdlExtraChannel.attribute);
    assert(member.ordinal == 3);
    assert(member.name.namespace_ == "x" && member.name.localName == "platform");
    assert(member.scalar.kind == SdlScalarKind.integer);
    assert(member.span.start.byteOffset == 1);

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
    static SdlScalar borrowAny(scope const ref SdlScalar s) @trusted
    {
        const ps = &s;
        return *ps;
    }

    static SdlQualifiedName borrowName(scope const ref SdlQualifiedName n)
        @trusted
    {
        const pn = &n;
        return *pn;
    }

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
