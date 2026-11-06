/**
SDL role attributes and the compile-time SDL projection of the shared schema.

This module supplies the six SPEC §5 role UDAs — $(LREF SdlTagValue),
$(LREF SdlAttribute), $(LREF SdlChild), $(LREF SdlTagName),
$(LREF SdlTagNamespace), and $(LREF SdlExtra) — plus the `Sdl` format marker
and $(LREF sdlAggregateRoles), the per-aggregate role projection consumed by
`wireSchemaOf!(Sdl, T)`.

Design contract (SPEC §1.1): SDL roles are resolved into the *shared* schema
once. This module never rebuilds a shadow schema — it reads the reified
`wireSchemaOf!(Sdl, T)` arena for shape facts (node kinds, extents) and adds
only a thin per-aggregate sidecar keyed by field node index. Every SPEC §5.2
shape rule is enforced here as a compile-time diagnostic naming the aggregate,
field, role, and required shape. Role UDAs have zero effect under other
formats: they never touch `@Wire*` resolution, so JSON schemas and digests are
unchanged.
*/
module sparkles.wired.sdl.schema_annotations;

import std.meta : AliasSeq, staticIndexOf;
import std.traits : ForeachType, ValueType, getUDAs, isAssociativeArray,
    isDynamicArray, isSomeString, isStaticArray, Unqual;
import std.typecons : Nullable;

import optional : Optional;

import sparkles.wired.policy : AnyFormat, Repr, WireStrict, hasExplicitWireName,
    hasWireStrict, hasConvert, convertOf;
import sparkles.wired.adapters : Same;
import sparkles.wired.schema : NodeKind, ScalarKind, WireSchema,
    isWirePassthrough, rawWireSchemaOf, wireSchemaOf;
import sparkles.wired.sdl.document : OwnedSdlExtras, SdlExtras, SdlQualifiedName;
import sparkles.wired.sdl.lexer : isSdlIdentifier;

// ── Format marker ────────────────────────────────────────────────────────────

/// The SDL format tag: `wireSchemaOf!(Sdl, T)`, `@WireName!Sdl("ns:name")`, …
struct Sdl
{
    /// SDL text APIs require an owned aggregate root and representable scalars.
    template roundTripSchema(T, alias schema)
    {
        enum bool roundTripSchema = () {
            static if (!is(T == struct))
                return false;
            else static if (hasBorrowedSdlExtras!(Unqual!T)
                || !__traits(compiles, sdlAggregateRoles!(Unqual!T, true)))
                return false;
            else
            {
                foreach (role; sdlAggregateRoles!(Unqual!T, true).sdlFieldRoles.roles)
                    if (role.role != SdlRoleKind.child && role.role != SdlRoleKind.extra)
                        return false;
                foreach (node; schema.nodes)
                    if (node.scalarKind == ScalarKind.sysTime
                        || (node.scalarKind == ScalarKind.unsignedInteger
                            && node.scalarBits >= 64))
                        return false;
                return true;
            }
        }();
    }

    /// Format hook invoked by the shared schema boundary, before publication.
    template validateWireSchema(T, alias schema)
    {
        enum bool validateWireSchema = validateSdlType!T;
    }
}

/* Validates every aggregate type reachable from `T`, including those behind
containers and null-aware wrappers, through its type-keyed projection
($(LREF sdlAggregateRoles)): a type is projected once per compilation however
many arena nodes it occupies. Converted types and fields stop the descent, as
their wire shape is the converter's; `Seen` ends recursion through a type
that reaches itself.
*/
private template validateSdlType(T, Seen...)
{
    private alias U = Unqual!T;
    static if (staticIndexOf!(U, Seen) >= 0 || hasConvert!(Sdl, U) || isWirePassthrough!U)
        enum bool validateSdlType = true;
    else static if (is(U == Nullable!N, N) || is(U == Optional!N, N))
        enum bool validateSdlType = validateSdlType!(N, Seen);
    else static if (isStaticArray!U || (isDynamicArray!U && !isSomeString!U))
        enum bool validateSdlType = validateSdlType!(ForeachType!U, Seen);
    else static if (isAssociativeArray!U)
        enum bool validateSdlType = validateSdlType!(ValueType!U, Seen);
    else static if (is(U == struct)
        && rawWireSchemaOf!(Sdl, U).nodes[0].kind == NodeKind.aggregate)
    {
        static assert(sdlAggregateRoles!U.sdlFieldRoles.roles.length == U.tupleof.length);
        static foreach (i; 0 .. U.tupleof.length)
            static assert(validateSdlFieldMetadata!(U, i)
                && (hasConvert!(Sdl, U.tupleof[i], typeof(U.tupleof[i]))
                    || validateSdlType!(typeof(U.tupleof[i]), Seen, U)));
        enum bool validateSdlType = true;
    }
    else
        enum bool validateSdlType = true;
}

private template validateSdlFieldMetadata(T, size_t i)
{
    static if (hasConvert!(Sdl, T.tupleof[i], typeof(T.tupleof[i])))
    {
        alias Converter = convertOf!(Sdl, T.tupleof[i], typeof(T.tupleof[i]));
        static if (__traits(hasMember, Converter, "KeyAdapter"))
            static assert(is(Converter.KeyAdapter == Same),
                "wired.sdl: " ~ T.stringof ~ "." ~ __traits(identifier, T.tupleof[i])
                ~ " map role requires the Same key adapter");
    }
    enum bool validateSdlFieldMetadata = true;
}

// ── Role UDAs ────────────────────────────────────────────────────────────────

/** Positional tag value beginning at zero-based `index` (SPEC §5).

Parentheses are mandatory (`@SdlTagValue(0)`), keeping every role UDA a
uniform compile-time value like the rest of the wired attribute surface.
*/
struct SdlTagValueAttr
{
    size_t index; /// the zero-based positional slot this field consumes
}

/// ditto
SdlTagValueAttr SdlTagValue(size_t index) @safe pure nothrow @nogc
    => SdlTagValueAttr(index);

/// Named attribute; the key resolves through `@WireName!Sdl` / `@WireCase!Sdl`.
struct SdlAttributeAttr
{
}

/// ditto
SdlAttributeAttr SdlAttribute() @safe pure nothrow @nogc => SdlAttributeAttr();

/// Named child tag; sequences represent repeated sibling tags (SPEC §5).
struct SdlChildAttr
{
}

/// ditto
SdlChildAttr SdlChild() @safe pure nothrow @nogc => SdlChildAttr();

/// Dynamic local name of the containing tag — a data field, not payload data.
struct SdlTagNameAttr
{
}

/// ditto
SdlTagNameAttr SdlTagName() @safe pure nothrow @nogc => SdlTagNameAttr();

/// Dynamic namespace of the containing tag — a data field, not payload data.
struct SdlTagNamespaceAttr
{
}

/// ditto
SdlTagNamespaceAttr SdlTagNamespace() @safe pure nothrow @nogc
    => SdlTagNamespaceAttr();

/// Ordered unmatched values, attributes, and children (SPEC §8 placeholder).
struct SdlExtraAttr
{
}

/// ditto
SdlExtraAttr SdlExtra() @safe pure nothrow @nogc => SdlExtraAttr();

// ── Projected sidecar ────────────────────────────────────────────────────────

/// The SDL channel an aggregate field occupies (SPEC §5).
package enum SdlRoleKind : ubyte
{
    child,         /// named child tag (the unannotated default)
    tagValue,      /// positional value of the containing tag
    attribute,     /// named attribute of the containing tag
    tagName,       /// dynamic local-name data field
    tagNamespace,  /// dynamic namespace data field
    extra,         /// ordered unmatched-capture placeholder (SPEC §8)
}

/// How a `child`-role field maps onto child tags (SPEC §5.2).
package enum SdlChildShape : ubyte
{
    none,               /// not a `child` role
    scalarSingle,       /// one child whose positional value 0 is the scalar
    aggregateSingle,    /// one named child whose body is the aggregate
    scalarSequence,     /// values appended from every matching occurrence
    aggregateSequence,  /// one sibling child per element
    map,                /// one child per entry keyed by the entry key
}

/** One aggregate field's resolved SDL role — plain schema data (SPEC §5). */
package struct SdlFieldRole
{
    size_t fieldIndex;   /// position in `T.tupleof`
    size_t nodeIndex;    /// schema arena index of the field's payload node
    SdlRoleKind role;    /// which SDL channel the field occupies
    string namespace_;   /// resolved namespace; empty = ordinary SDL name
    string localName;    /// resolved local name (case policy or explicit split)
    const(SdlQualifiedName)[] aliases; /// decode-only qualified identities
    size_t positionalIndex = size_t.max; /// `tagValue`: the declared slot
    bool dynamicValueSuffix;             /// `tagValue`: dynamic-array suffix
    bool dynamicName;                    /// `tagName` data field
    bool dynamicNamespace;               /// `tagNamespace` data field
    SdlChildShape childShape = SdlChildShape.none; /// `child` role only
    size_t staticCount;  /// exact positions/attributes for static arrays
}

/** One aggregate's projected SDL roles, keyed by field node index. */
package struct SdlAggregateRoles
{
    /// Schema node indices of the fields, parallel to $(LREF roles).
    size_t[] fieldNodeIndices;
    /// Resolved roles in declaration order, one per field.
    SdlFieldRole[] roles;
    /// Whether `@WireStrict` (exact `Sdl` or `AnyFormat`) applies — unknown
    /// members are decode errors instead of being ignored (SPEC §8 forbid).
    bool strictUnknown;
}

private enum Shape : ubyte
{
    scalarSingle,
    aggregateSingle,
    seqScalar,
    seqAggregate,
    map,
    other,
}

private size_t payloadIndex(const WireSchema schema, size_t index)
{
    while (true)
    {
        const node = schema.nodes[index];
        if (node.kind == NodeKind.reference)
            index = node.referenceIndex;
        else if (node.kind == NodeKind.converted
            || (node.kind == NodeKind.nullAware && node.edgeCount))
            index = schema.edges[node.firstEdge];
        else
            return index;
    }
}

private Shape shapeAt(const WireSchema s, size_t ni)
{
    final switch (s.nodes[ni].kind)
    {
    case NodeKind.scalar:
    case NodeKind.enumeration:
        return Shape.scalarSingle;
    case NodeKind.aggregate:
        return Shape.aggregateSingle;
    case NodeKind.reference:
        return shapeAt(s, s.nodes[ni].referenceIndex);
    case NodeKind.converted:
        return shapeAt(s, s.edges[s.nodes[ni].firstEdge]);
    case NodeKind.nullAware:
        return s.nodes[ni].edgeCount == 0 ? Shape.scalarSingle
            : shapeAt(s, s.edges[s.nodes[ni].firstEdge]);
    case NodeKind.sequence:
        return shapeElement(s, s.edges[s.nodes[ni].firstEdge], false);
    case NodeKind.staticArray:
        return shapeElement(s, s.edges[s.nodes[ni].firstEdge], true);
    case NodeKind.map:
        return Shape.map;
    case NodeKind.unionType:
    {
        // A union whose every variant is scalar-convertible is itself
        // scalar-convertible for attribute/value channels (SPEC §6).
        foreach (edge; s.edges[s.nodes[ni].firstEdge
                .. s.nodes[ni].firstEdge + s.nodes[ni].edgeCount])
            if (shapeAt(s, edge) != Shape.scalarSingle)
                return Shape.other;
        return Shape.scalarSingle;
    }
    case NodeKind.passthrough:
        return Shape.other;
    }
}

private Shape shapeElement(const WireSchema s, size_t elementIndex, bool)
{
    final switch (shapeAt(s, elementIndex))
    {
    case Shape.scalarSingle:
        return Shape.seqScalar;
    case Shape.aggregateSingle:
        return Shape.seqAggregate;
    case Shape.seqScalar:
    case Shape.seqAggregate:
    case Shape.map:
    case Shape.other:
        return Shape.other;
    }
}

/// Whether the node serializes as a string or a name-represented enum —
/// the required type class for AA keys and dynamic tag-name fields.
private bool nameBearing(const WireSchema s, size_t ni)
{
    const target = s.nodes[ni].kind == NodeKind.reference
        ? s.nodes[ni].referenceIndex : ni;
    const node = s.nodes[target];
    if (node.kind == NodeKind.enumeration)
        return node.policy.repr == Repr.name;
    if (node.kind == NodeKind.converted || node.kind == NodeKind.nullAware)
        return nameBearing(s, s.edges[node.firstEdge]);
    return node.kind == NodeKind.scalar && node.scalarKind == ScalarKind.string;
}

private string roleName(SdlRoleKind role)
{
    final switch (role)
    {
    case SdlRoleKind.child: return "SdlChild";
    case SdlRoleKind.tagValue: return "SdlTagValue";
    case SdlRoleKind.attribute: return "SdlAttribute";
    case SdlRoleKind.tagName: return "SdlTagName";
    case SdlRoleKind.tagNamespace: return "SdlTagNamespace";
    case SdlRoleKind.extra: return "SdlExtra";
    }
}

// ── Qualified-name resolution ────────────────────────────────────────────────

private SdlQualifiedName aliasName(string name) @safe pure nothrow @nogc
{
    foreach (i, c; name)
        if (c == ':')
            return SdlQualifiedName(name[0 .. i], name[i + 1 .. $]);
    return SdlQualifiedName(null, name);
}

// A qualified SDL name split into its two halves.
private struct SplitName
{
    string namespace_;
    string localName;
}

/* Splits one qualified SDL spelling — a field's resolved key — into namespace
and local name. A colon splits exactly once; an empty spelling, empty halves
and additional colons append a diagnostic naming the aggregate and field to
`err` (SPEC §5.1).
*/
private SplitName splitQualifiedName(string aggregate, string field, string raw,
    ref string err) @safe pure nothrow
{
    if (raw.length == 0)
    {
        err ~= "wired.sdl: " ~ aggregate ~ "." ~ field
            ~ ": qualified SDL name must not be empty";
        return SplitName.init;
    }
    ptrdiff_t firstColon = -1, lastColon = -1;
    foreach (i, c; raw)
        if (c == ':')
        {
            if (firstColon < 0)
                firstColon = i;
            lastColon = i;
        }
    if (firstColon < 0)
        return SplitName(null, raw);
    if (firstColon != lastColon)
        err ~= "wired.sdl: " ~ aggregate ~ "." ~ field
            ~ ": qualified SDL name \"" ~ raw ~ "\" must contain exactly one ':'";
    else if (firstColon == 0 || lastColon == raw.length - 1)
        err ~= "wired.sdl: " ~ aggregate ~ "." ~ field
            ~ ": qualified SDL name \"" ~ raw
            ~ "\" must not have an empty namespace or local half";
    else
        return SplitName(raw[0 .. firstColon], raw[firstColon + 1 .. $]);
    return SplitName.init;
}

// ── The SDL projection ───────────────────────────────────────────────────────

// What one field declares for SDL: its resolved role UDA and the type facts
// the schema arena does not record.
private struct SdlFieldFacts
{
    string ident;            // the D identifier
    size_t roleCount;        // role UDAs present; more than one is an error
    SdlRoleKind role;        // the resolved role, `child` when unannotated
    size_t declaredIndex = size_t.max; // `@SdlTagValue(i)`: `i`
    bool explicitName;       // carries an explicit `@WireName!Sdl`
    bool extrasType;         // is `SdlExtras` or `OwnedSdlExtras`
}

// Whether attribute `uda` is role attribute `Attr`, as a value or as the type.
private enum bool isRoleUda(alias uda, Attr) = is(typeof(uda) == Attr) || is(uda == Attr);

// `T`'s field facts, read in one pass over each field's attributes.
private enum SdlFieldFacts[] sdlFieldFacts(T) = () {
    SdlFieldFacts[] facts;
    static foreach (i; 0 .. T.tupleof.length)
    {{
        SdlFieldFacts f;
        f.ident = __traits(identifier, T.tupleof[i]);
        size_t tagValues, attributes, children, tagNames, tagNamespaces, extras;
        static foreach (uda; __traits(getAttributes, T.tupleof[i]))
        {
            static if (isRoleUda!(uda, SdlTagValueAttr))
            {
                static if (!is(uda))
                    if (tagValues == 0)
                        f.declaredIndex = uda.index;
                tagValues++;
            }
            else static if (isRoleUda!(uda, SdlAttributeAttr))
                attributes++;
            else static if (isRoleUda!(uda, SdlChildAttr))
                children++;
            else static if (isRoleUda!(uda, SdlTagNameAttr))
                tagNames++;
            else static if (isRoleUda!(uda, SdlTagNamespaceAttr))
                tagNamespaces++;
            else static if (isRoleUda!(uda, SdlExtraAttr))
                extras++;
        }
        f.roleCount = tagValues + attributes + children + tagNames + tagNamespaces + extras;
        f.role = tagValues ? SdlRoleKind.tagValue
            : attributes ? SdlRoleKind.attribute
            : tagNames ? SdlRoleKind.tagName
            : tagNamespaces ? SdlRoleKind.tagNamespace
            : extras ? SdlRoleKind.extra
            : SdlRoleKind.child;
        f.explicitName = hasExplicitWireName!(Sdl, T.tupleof[i]);
        f.extrasType = is(typeof(T.tupleof[i]) == SdlExtras)
            || is(typeof(T.tupleof[i]) == OwnedSdlExtras);
        facts ~= f;
    }}
    return facts;
}();

// The projected roles, or the §5.2 diagnostics that reject the aggregate.
private struct SdlProjection
{
    string error;
    SdlAggregateRoles roles;
}

/* Validates and projects the roles of the aggregate at node 0 of `schema`,
whose fields `facts` describes, in a single CTFE evaluation over one copy of
the arena. `aggregate` names the type in diagnostics.
*/
private SdlProjection projectSdlRoles(const WireSchema schema,
    const(SdlFieldFacts)[] facts, string aggregate, bool strictUnknown)
{
    import std.conv : to;

    SdlProjection projection;
    const rootNode = schema.nodes[0];
    if (rootNode.kind != NodeKind.aggregate)
    {
        projection.error = "wired.sdl: " ~ aggregate
            ~ ": SDL document root must be an unconverted aggregate";
        return projection;
    }
    assert(rootNode.edgeCount == facts.length);

    string err;
    int tagNameSeen, tagNsSeen, extraSeen;
    size_t[] occupied;
    bool hasDynamicSuffix;
    size_t dynamicIndex;
    bool anyFixedIndex;
    size_t maxFixedIndex;

    void occupy(size_t from, size_t count, string where_)
    {
        foreach (p; from .. from + count)
        {
            foreach (existing; occupied)
                if (existing == p)
                {
                    err ~= "wired.sdl: " ~ aggregate ~ "." ~ where_
                        ~ ": positional value slot " ~ p.to!string
                        ~ " is already claimed by another"
                        ~ " @SdlTagValue field";
                    return;
                }
            occupied ~= p;
        }
    }

    void claimFixed(size_t end)
    {
        maxFixedIndex = anyFixedIndex && maxFixedIndex > end ? maxFixedIndex : end;
        anyFixedIndex = true;
    }

    projection.roles.strictUnknown = strictUnknown;
    foreach (i, f; facts)
    {
        const ni = schema.edges[rootNode.firstEdge + i];
        const policy = schema.nodes[ni].policy.field;
        const named = f.role == SdlRoleKind.child || f.role == SdlRoleKind.attribute;
        const shape = named || f.role == SdlRoleKind.tagValue ? shapeAt(schema, ni) : Shape.other;
        const payload = schema.nodes[payloadIndex(schema, ni)];
        const staticLength = payload.staticLength;
        // A runtime-length wrapper marks a dynamic value-suffix sequence.
        const dynamicArrayWrapper = payload.kind == NodeKind.sequence;

        if (f.roleCount > 1)
            err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                ~ ": a field declares at most one SDL role UDA";

        SplitName name = SplitName(null, policy.key);
        if (named || f.explicitName)
            name = splitQualifiedName(aggregate, f.ident, policy.key, err);
        if (named)
        {
            if (!isSdlIdentifier(name.localName)
                || (name.namespace_.length && !isSdlIdentifier(name.namespace_)))
                err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                    ~ ": @" ~ roleName(f.role)
                    ~ " requires a valid qualified SDL identifier";
            foreach (rawAlias; policy.aliases)
            {
                const alias_ = aliasName(rawAlias);
                if (!isSdlIdentifier(alias_.localName)
                    || (alias_.namespace_.length && !isSdlIdentifier(alias_.namespace_)))
                    err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                        ~ ": @" ~ roleName(f.role)
                        ~ " alias requires a valid qualified SDL identifier";
            }
        }

        SdlFieldRole role;
        role.fieldIndex = i;
        role.nodeIndex = ni;
        role.role = f.role;
        foreach (rawAlias; policy.aliases)
            role.aliases ~= aliasName(rawAlias);
        role.namespace_ = f.explicitName ? name.namespace_ : null;
        role.localName = f.explicitName ? name.localName : policy.key;

        final switch (f.role)
        {
        case SdlRoleKind.child:
            final switch (shape)
            {
            case Shape.scalarSingle:
                role.childShape = SdlChildShape.scalarSingle;
                break;
            case Shape.aggregateSingle:
                role.childShape = SdlChildShape.aggregateSingle;
                break;
            case Shape.seqScalar:
                role.childShape = SdlChildShape.scalarSequence;
                role.staticCount = staticLength;
                break;
            case Shape.seqAggregate:
                role.childShape = SdlChildShape.aggregateSequence;
                break;
            case Shape.map:
                role.childShape = SdlChildShape.map;
                const keyNode = schema.edges[schema.nodes[payloadIndex(schema, ni)].firstEdge];
                if (!nameBearing(schema, keyNode))
                    err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                        ~ ": an associative-array @SdlChild requires "
                        ~ "string or name-represented enum keys";
                break;
            case Shape.other:
                err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                    ~ ": @SdlChild requires a scalar, an aggregate, a "
                    ~ "scalar or aggregate sequence/static array, or a "
                    ~ "map with string/enum keys";
                break;
            }
            break;
        case SdlRoleKind.tagValue:
            role.positionalIndex = f.declaredIndex;
            role.dynamicValueSuffix = shape == Shape.seqScalar && dynamicArrayWrapper;
            role.staticCount = staticLength;
            final switch (shape)
            {
            case Shape.scalarSingle:
                claimFixed(f.declaredIndex);
                occupy(f.declaredIndex, 1, f.ident);
                break;
            case Shape.seqScalar:
                if (!dynamicArrayWrapper)
                {
                    claimFixed(f.declaredIndex + staticLength - 1);
                    occupy(f.declaredIndex, staticLength, f.ident);
                }
                else if (!hasDynamicSuffix)
                {
                    hasDynamicSuffix = true;
                    dynamicIndex = f.declaredIndex;
                }
                else
                    err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                        ~ ": at most one dynamic @SdlTagValue "
                        ~ "sequence may consume a suffix per aggregate";
                break;
            case Shape.aggregateSingle:
            case Shape.seqAggregate:
            case Shape.map:
            case Shape.other:
                err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                    ~ ": @SdlTagValue requires a scalar-convertible "
                    ~ "field or a sequence/static array of them";
                break;
            }
            break;
        case SdlRoleKind.attribute:
            role.staticCount = staticLength;
            if (shape != Shape.scalarSingle && shape != Shape.seqScalar)
                err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                    ~ ": @SdlAttribute must be scalar-convertible "
                    ~ "(a sequence means repeated attributes); nested "
                    ~ "aggregates and maps are unsupported";
            break;
        case SdlRoleKind.tagName:
            role.dynamicName = true;
            tagNameSeen++;
            if (!nameBearing(schema, ni))
                err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                    ~ ": @SdlTagName requires a string or "
                    ~ "name-represented enum field";
            break;
        case SdlRoleKind.tagNamespace:
            role.dynamicNamespace = true;
            tagNsSeen++;
            if (!nameBearing(schema, ni))
                err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                    ~ ": @SdlTagNamespace requires a string or "
                    ~ "name-represented enum field";
            break;
        case SdlRoleKind.extra:
            extraSeen++;
            if (!f.extrasType)
                err ~= "wired.sdl: " ~ aggregate ~ "." ~ f.ident
                    ~ ": @SdlExtra requires an SdlExtras (borrowed) or "
                    ~ "OwnedSdlExtras (owned) field";
            break;
        }
        projection.roles.fieldNodeIndices ~= ni;
        projection.roles.roles ~= role;
    }

    if (tagNameSeen > 1)
        err ~= "wired.sdl: " ~ aggregate
            ~ ": at most one @SdlTagName field per aggregate";
    if (tagNsSeen > 1)
        err ~= "wired.sdl: " ~ aggregate
            ~ ": at most one @SdlTagNamespace field per aggregate";
    if (extraSeen > 1)
        err ~= "wired.sdl: " ~ aggregate
            ~ ": at most one @SdlExtra field per aggregate";
    if (extraSeen && strictUnknown)
        err ~= "wired.sdl: " ~ aggregate
            ~ ": @WireStrict and @SdlExtra are contradictory unknown-"
            ~ "member policies (forbid versus preserve)";
    // With no fixed slots at all, index 0 *is* the greatest declared
    // index; comparing against a zero-initialized `maxFixedIndex` rejects
    // the most natural positional shape there is (`tag "a" "b" "c"`).
    if (hasDynamicSuffix && anyFixedIndex && dynamicIndex <= maxFixedIndex)
        err ~= "wired.sdl: " ~ aggregate
            ~ ": the dynamic @SdlTagValue sequence must have the "
            ~ "greatest declared index";
    projection.error = err;
    return projection;
}

// The SPEC §5 diagnostics for dynamic identity fields on a document root.
private string sdlDocumentRootError(string aggregate, const(SdlFieldFacts)[] facts)
    @safe pure nothrow
{
    string err, dynamicNameAt, dynamicNsAt;
    foreach (f; facts)
        if (f.role == SdlRoleKind.tagName)
            dynamicNameAt = f.ident;
        else if (f.role == SdlRoleKind.tagNamespace)
            dynamicNsAt = f.ident;
    if (dynamicNameAt.length)
        err ~= "wired.sdl: " ~ aggregate ~ "." ~ dynamicNameAt
            ~ ": @SdlTagName is forbidden on synthetic document roots";
    if (dynamicNsAt.length)
        err ~= "wired.sdl: " ~ aggregate ~ "." ~ dynamicNsAt
            ~ ": @SdlTagNamespace is forbidden on synthetic document roots";
    return err;
}

/** Resolves every field's SDL role for aggregate `T` (SPEC §5/§5.2).

The result is plain schema data keyed by field node index into
`wireSchemaOf!(Sdl, T)`: role kind, positional index, resolved
namespace/local-name pair, dynamic-name/namespace flags, child-shape markers,
and static-array extents. Unannotated serializable fields default to the
$(LREF SdlRoleKind.child) role.

Every §5.2 shape rule is enforced as a `static assert` naming the aggregate,
field, role, and required shape:

$(LIST
    * attributes must be scalar-convertible — sequences mean repeated
    attributes with the same qualified name; aggregates and maps are
    unsupported;
    * children follow $(LREF SdlChildShape): scalars, aggregates, scalar or
    aggregate sequences, static scalar arrays (exact count), maps keyed by
    strings or enums;
    * positional values must be scalar-convertible (or sequences/static arrays
    thereof), positions unique, and at most one dynamic sequence suffix with
    the greatest declared index; static arrays occupy exact positions;
    * at most one $(LREF SdlTagName), $(LREF SdlTagNamespace), and
    $(LREF SdlExtra) per aggregate; tag-name/namespace fields must be
    `string` or name-represented enums;
    * an `@SdlExtra` field must have type $(LREF SdlExtras) (borrowed) or
    $(LREF OwnedSdlExtras) (owned);
    * `@WireStrict` together with `@SdlExtra` is a compile-time contradiction —
    forbid versus preserve (SPEC §8); the diagnostic names the aggregate;
    * when `isDocumentRoot`, dynamic identity fields are forbidden on the root
    aggregate.
)

The projection also resolves the aggregate's unknown-member policy:
$(LREF SdlAggregateRoles.strictUnknown) reports whether `@WireStrict!Sdl`
(or the format-less spelling) applies.

The projection is keyed by `T` alone and computed once per compilation, in
one CTFE evaluation over the type's own arena; the document-root form adds
its check and shares that storage.
*/
package template sdlAggregateRoles(T, bool isDocumentRoot = false)
if (is(T == struct))
{
    static if (isDocumentRoot)
    {
        private enum string rootError = sdlDocumentRootError(T.stringof, sdlFieldFacts!T);
        static assert(rootError.length == 0, rootError);
        alias sdlFieldRoles = sdlAggregateRoles!T.sdlFieldRoles;
    }
    else
    {
        private enum SdlProjection projection = projectSdlRoles(rawWireSchemaOf!(Sdl, T),
            sdlFieldFacts!T, T.stringof, hasWireStrict!(Sdl, T) || hasWireStrict!(AnyFormat, T));
        static assert(projection.error.length == 0, projection.error);
        // Keep runtime storage keyed by type, not by the schema value: a
        // large recipe schema otherwise produces a symbol too long for PDB.
        static immutable SdlAggregateRoles sdlFieldRoles = projection.roles;
    }
}

// ── Unknown-member helpers ───────────────────────────────────────────────────

/** Whether aggregate `T` — or any aggregate reachable from its fields —
declares its $(LREF SdlExtra) field with the *borrowed* $(LREF SdlExtras)
flavor.

Such aggregates decode only from a caller-kept-alive $(LREF SdlNode): the text
convenience overload rejects them at compile time because its temporary
document cannot outlive the returned value (SPEC §8).

Reachability follows container indirection. A borrowed capture nested behind a
sequence, static array, associative-array value, or null-aware wrapper aliases
the source arena exactly as a direct field does, so stopping the descent at
the first non-struct field would let `fromSDL!T(text)` compile for a type
whose decoded value points into a freed document.
*/
package template hasBorrowedSdlExtras(T)
if (is(T == struct))
{
    enum bool hasBorrowedSdlExtras = borrowedInAggregate!(Unqual!T);
}

/** Peels container indirection down to the aggregate a field can carry.

Everything here keeps a borrowed capture alive just as a direct field would;
anything else bottoms out as itself and fails the `struct` test below.
*/
private template borrowedCarrier(F)
{
    static if (isDynamicArray!F || isStaticArray!F)
        alias borrowedCarrier = borrowedCarrier!(Unqual!(ForeachType!F));
    else static if (isAssociativeArray!F)
        alias borrowedCarrier = borrowedCarrier!(Unqual!(ValueType!F));
    else static if (is(F == Nullable!N, N))
        alias borrowedCarrier = borrowedCarrier!(Unqual!N);
    else static if (is(F == Optional!O, O))
        alias borrowedCarrier = borrowedCarrier!(Unqual!O);
    else
        alias borrowedCarrier = F;
}

/** Whether `T` or anything reachable from it carries a borrowed capture.

`Seen` guards the recursion: once containers are followed, a type can reach
itself (`struct Node { Node[] children; }` is legal D), so a plain descent
would not terminate.
*/
private template borrowedInAggregate(T, Seen...)
{
    static if (!is(T == struct) || isWirePassthrough!T
        || staticIndexOf!(T, Seen) >= 0)
        enum bool borrowedInAggregate = false;
    else
        enum bool borrowedInAggregate = borrowedExtrasAt!(T, 0)
            || borrowedNestedFields!(T, 0, AliasSeq!(Seen, T));
}

/// Whether field `i`.. of `T` carries an annotated borrowed-extras field.
private template borrowedExtrasAt(T, size_t i)
{
    static if (i >= T.tupleof.length)
        enum bool borrowedExtrasAt = false;
    else static if (getUDAs!(T.tupleof[i], SdlExtraAttr).length
        && is(typeof(T.tupleof[i]) == SdlExtras))
        enum bool borrowedExtrasAt = true;
    else
        enum bool borrowedExtrasAt = borrowedExtrasAt!(T, i + 1);
}

private template borrowedNestedFields(T, size_t i, Seen...)
{
    static if (i >= T.tupleof.length)
        enum bool borrowedNestedFields = false;
    else static if (borrowedInAggregate!(
            borrowedCarrier!(Unqual!(typeof(T.tupleof[i]))), Seen))
        enum bool borrowedNestedFields = true;
    else
        enum bool borrowedNestedFields = borrowedNestedFields!(T, i + 1, Seen);
}
// ── Tests ────────────────────────────────────────────────────────────────────
version (unittest)
{
    private import std.algorithm.searching : canFind;

    import sparkles.wired.json : Json;
    import sparkles.wired.policy : CaseStyle, WireCase, WireName;
    import sparkles.wired.schema : wireSchemaDigest;

    private struct Dep
    {
        string id;
    }

    @WireCase!Sdl(CaseStyle.snakeCase)
    private struct Kitchen
    {
        int plainChild;
        @WireName!Sdl("x:platform") string renamed;
        @SdlTagValue(0) string name;
        @SdlTagValue(1) int[2] pair;
        @SdlTagValue(3) string[] rest;
        @SdlAttribute() string[] aliases;
        @SdlChild() bool flag;
        @SdlChild() Dep dep;
        @SdlChild() string[] tags;
        @SdlChild() Dep[] deps;
        @SdlChild() Dep[string] byId;
        @SdlTagName() string tagNameField;
        @SdlTagNamespace() string tagNsField;
        @SdlExtra() SdlExtras extras;
    }

    private struct Plain
    {
        int plainChild;
        string renamed;
        string name;
        int[2] pair;
        string[] rest;
        string[] aliases;
        bool flag;
        Dep dep;
        string[] tags;
        Dep[] deps;
        Dep[string] byId;
        string tagNameField;
        string tagNsField;
        SdlExtras extras;
    }
}

// Role UDAs survive verbatim in every format's open annotation list.
@("wired.sdl.schema.roleUdasSurviveAsAnnotations")
@safe pure unittest
{
    static struct Shape
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() bool optionalFlag;
        @SdlChild() Dep dep;
        @SdlTagName() string tag;
        @SdlExtra() SdlExtras extras;
    }

    enum jsonSchema = wireSchemaOf!(Json, Shape);
    static foreach (i; 0 .. 5)
    {{
        const fieldNode = jsonSchema.edges[jsonSchema.nodes[0].firstEdge + i];
        static assert(jsonSchema.nodes[fieldNode].annotationCount >= 1);
    }}
    const valueNode = jsonSchema.edges[jsonSchema.nodes[0].firstEdge];
    static assert(jsonSchema.annotations[jsonSchema.nodes[valueNode]
        .firstAnnotation].typeName == "SdlTagValueAttr");
    static assert(jsonSchema.annotations[jsonSchema.nodes[valueNode]
        .firstAnnotation].value.canFind("0"));

    enum sdlSchema = wireSchemaOf!(Sdl, Shape);
    const sdlValueNode = sdlSchema.edges[sdlSchema.nodes[0].firstEdge];
    static assert(sdlSchema.annotations[sdlSchema.nodes[sdlValueNode]
        .firstAnnotation].typeName == "SdlTagValueAttr");
}

// Compile-time snapshot of the projected sidecar for every role composition.
@("wired.sdl.schema.projection.snapshot")
@safe pure unittest
{
    enum roles = sdlAggregateRoles!(Kitchen).sdlFieldRoles;
    enum R = roles.roles;

    static assert(R.length == 14);
    static assert(roles.fieldNodeIndices.length == R.length);
    static foreach (i; 0 .. R.length)
        static assert(R[i].fieldIndex == i);

    static assert(R[0].role == SdlRoleKind.child);
    static assert(R[0].namespace_.length == 0
        && R[0].localName == "plain_child");
    static assert(R[0].childShape == SdlChildShape.scalarSingle);

    static assert(R[1].localName == "platform" && R[1].namespace_ == "x");
    static assert(R[1].childShape == SdlChildShape.scalarSingle);

    static assert(R[2].role == SdlRoleKind.tagValue
        && R[2].positionalIndex == 0 && !R[2].dynamicValueSuffix);

    static assert(R[3].positionalIndex == 1 && R[3].staticCount == 2);

    static assert(R[4].positionalIndex == 3 && R[4].dynamicValueSuffix);

    static assert(R[5].role == SdlRoleKind.attribute
        && R[5].localName == "aliases");

    static assert(R[6].childShape == SdlChildShape.scalarSingle);
    static assert(R[7].childShape == SdlChildShape.aggregateSingle);
    static assert(R[8].childShape == SdlChildShape.scalarSequence);
    static assert(R[9].childShape == SdlChildShape.aggregateSequence);
    static assert(R[10].childShape == SdlChildShape.map);

    static assert(R[11].role == SdlRoleKind.tagName && R[11].dynamicName);
    static assert(R[12].role == SdlRoleKind.tagNamespace
        && R[12].dynamicNamespace);
    static assert(R[13].role == SdlRoleKind.extra);

    // Field node indices agree with the shared schema arena's root edges.
    enum kitchenSchema = wireSchemaOf!(Sdl, Kitchen);
    static foreach (i; 0 .. R.length)
        static assert(roles.fieldNodeIndices[i] == kitchenSchema.edges[
            kitchenSchema.nodes[0].firstEdge + i]);
}

// Runtime metadata has a bounded symbol name even for a rich schema.
@("wired.sdl.schema.runtimeStorageUsesTypeIdentity")
@safe pure nothrow @nogc unittest
{
    // A schema value in the storage template's arguments grows with every
    // field and annotation. Keep that CTFE data out of linker symbol names.
    static assert(sdlAggregateRoles!Kitchen.sdlFieldRoles.mangleof.length < 256);
    assert(sdlAggregateRoles!Kitchen.sdlFieldRoles.roles.length == 14);
}

// JSON schemas and digests are byte-identical for SDL-annotated types.
@("wired.sdl.schema.jsonSurfaceUnchanged")
@safe pure unittest
{
    static assert(wireSchemaDigest!(Json, Plain).length == 16);
    static assert(wireSchemaDigest!(Json, Plain)
        == wireSchemaDigest!(Json, Kitchen));

    enum plainSchema = wireSchemaOf!(Json, Plain);
    enum annotatedSchema = wireSchemaOf!(Json, Kitchen);
    static assert(plainSchema.nodes.length == annotatedSchema.nodes.length);
    static foreach (i; 0 .. plainSchema.nodes.length)
        static assert(plainSchema.nodes[i].name == annotatedSchema.nodes[i].name
            && plainSchema.nodes[i].kind == annotatedSchema.nodes[i].kind);
}

// ── §5.2 negative compile fixtures ──────────────────────────────────────────

@("wired.sdl.schema.negativeShapes")
@safe pure unittest
{
    static struct DuplicatePositions
    {
        @SdlTagValue(0) int a;
        @SdlTagValue(0) int b;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!DuplicatePositions));

    static struct VariadicNotLast
    {
        @SdlTagValue(0) int[] tail;
        @SdlTagValue(1) int last;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!VariadicNotLast));

    // A lone dynamic suffix: with nothing fixed, slot 0 is trivially the
    // greatest declared index, so `tag "a" "b" "c"` must project.
    static struct SoleSuffix
    {
        @SdlTagValue(0) string[] all;
    }
    static assert(sdlAggregateRoles!SoleSuffix.sdlFieldRoles
        .roles[0].dynamicValueSuffix);

    // …and it still has to come after every fixed slot when there are some.
    static struct SuffixAfterFixed
    {
        @SdlTagValue(0) int head;
        @SdlTagValue(1) string[] rest;
    }
    static assert(sdlAggregateRoles!SuffixAfterFixed.sdlFieldRoles
        .roles[1].dynamicValueSuffix);
    static struct SuffixInsideStatic
    {
        @SdlTagValue(0) int[3] head;
        @SdlTagValue(2) string[] rest;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!SuffixInsideStatic));

    static struct TwoDynamicSuffixes
    {
        @SdlTagValue(0) int[] a;
        @SdlTagValue(1) string[] b;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!TwoDynamicSuffixes));

    static struct StaticOverlap
    {
        @SdlTagValue(0) int[2] pair;
        @SdlTagValue(1) int single;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!StaticOverlap));

    static struct AggregateAttribute
    {
        @SdlAttribute() Dep dep;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!AggregateAttribute));
    static assert(!__traits(compiles, wireSchemaOf!(Sdl, AggregateAttribute)));
    static struct NestedInvalid { AggregateAttribute[] children; }
    static assert(!__traits(compiles, wireSchemaOf!(Sdl, NestedInvalid)));

    static struct InvalidIdentifier
    {
        @WireName!Sdl("bad name") int field;
    }
    static assert(!__traits(compiles, wireSchemaOf!(Sdl, InvalidIdentifier)));

    static struct MapAttribute
    {
        @SdlAttribute() int[string] table;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!MapAttribute));

    static struct AggregatePosition
    {
        @SdlTagValue(0) Dep dep;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!AggregatePosition));

    static struct UnsupportedChild
    {
        @SdlChild() Dep[string][] listOfMaps;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!UnsupportedChild));

    static struct BadMapKeys
    {
        @SdlChild() Dep[float] byFloat;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!BadMapKeys));

    static struct EmptyLocalHalf
    {
        @WireName!Sdl("x:") int broken;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!EmptyLocalHalf));

    static struct EmptyNamespaceHalf
    {
        @WireName!Sdl(":local") int broken;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!EmptyNamespaceHalf));

    static struct DoubleColon
    {
        @WireName!Sdl("a:b:c") int broken;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!DoubleColon));

    static struct DuplicateIdentity
    {
        @SdlTagName() string a;
        @SdlTagName() string b;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!DuplicateIdentity));

    static struct TagNameBadType
    {
        @SdlTagName() int notAName;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!TagNameBadType));

    static struct RootViolation
    {
        @SdlTagNamespace() string ns;
        int payload;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!(RootViolation, true)));
    import sparkles.wired.sdl.codec : fromSDL, toSDL;
    static assert(!__traits(compiles, fromSDL!RootViolation("")));
    static assert(!__traits(compiles, toSDL(RootViolation.init)));

    static struct MultipleRolesOneField
    {
        @SdlChild() @SdlAttribute() int ambiguous;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!MultipleRolesOneField));

    // SPEC §8: @WireStrict (forbid) and @SdlExtra (preserve) are contradictory.
    @WireStrict!Sdl
    static struct StrictAndExtras
    {
        int plain;
        @SdlExtra() SdlExtras extras;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!StrictAndExtras));

    // The format-less spelling contradicts just the same.
    @WireStrict
    static struct AnyStrictAndExtras
    {
        int plain;
        @SdlExtra() OwnedSdlExtras extras;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!AnyStrictAndExtras));

    // An @SdlExtra field must be one of the two capture flavors.
    static struct BadExtraType
    {
        @SdlExtra() int extras;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!BadExtraType));

    // Strict alone is fine, in either spelling, and is projected.
    @WireStrict!Sdl
    static struct JustStrict
    {
        int plain;
    }
    static assert(sdlAggregateRoles!JustStrict.sdlFieldRoles.strictUnknown);

    @WireStrict
    static struct AnyStrict
    {
        int plain;
    }
    static assert(sdlAggregateRoles!AnyStrict.sdlFieldRoles.strictUnknown);

    static struct Lenient
    {
        int plain;
    }
    static assert(!sdlAggregateRoles!Lenient.sdlFieldRoles.strictUnknown);

    // The borrowed/owned flavor probe.
    static struct Borrowed
    {
        @SdlExtra() SdlExtras extras;
    }
    static struct Owned
    {
        @SdlExtra() OwnedSdlExtras extras;
    }
    static struct Neither
    {
        int plain;
    }
    static struct Wrapper
    {
        Borrowed inner;
    }
    static struct OwnerWrapper
    {
        Owned inner;
    }
    static assert(hasBorrowedSdlExtras!Borrowed);
    static assert(!hasBorrowedSdlExtras!Owned);
    static assert(!hasBorrowedSdlExtras!Neither);
    static assert(hasBorrowedSdlExtras!Wrapper);
    static assert(!hasBorrowedSdlExtras!OwnerWrapper);

    // Container indirection hides nothing: a borrowed capture behind a
    // sequence, static array, map value, or null-aware wrapper still aliases
    // the source arena, so the text overload must refuse these too. Missing
    // any of them hands back a value whose payload points into a freed
    // document — reachable from `@safe` code.
    static struct SeqWrapper { Borrowed[] items; }
    static struct StaticWrapper { Borrowed[2] pair; }
    static struct MapWrapper { Borrowed[string] byKey; }
    static struct NullableWrapper { Nullable!Borrowed maybe; }
    static struct OptionalWrapper { Optional!Borrowed maybe; }
    static struct DeepWrapper { SeqWrapper[][] nested; }
    static assert(hasBorrowedSdlExtras!SeqWrapper);
    static assert(hasBorrowedSdlExtras!StaticWrapper);
    static assert(hasBorrowedSdlExtras!MapWrapper);
    static assert(hasBorrowedSdlExtras!NullableWrapper);
    static assert(hasBorrowedSdlExtras!OptionalWrapper);
    static assert(hasBorrowedSdlExtras!DeepWrapper);

    // The owned flavor stays free of the obligation through the same shapes.
    static struct OwnedSeqWrapper { Owned[] items; }
    static struct OwnedMapWrapper { Owned[string] byKey; }
    static assert(!hasBorrowedSdlExtras!OwnedSeqWrapper);
    static assert(!hasBorrowedSdlExtras!OwnedMapWrapper);

    // Following containers makes self-reference reachable; the descent must
    // still terminate.
    static struct Recursive { Recursive[] children; int leaf; }
    static struct RecursiveBorrowing
    {
        RecursiveBorrowing[] children;
        @SdlExtra() SdlExtras extras;
    }
    static assert(!hasBorrowedSdlExtras!Recursive);
    static assert(hasBorrowedSdlExtras!RecursiveBorrowing);
}
