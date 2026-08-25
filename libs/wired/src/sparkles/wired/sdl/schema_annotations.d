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

import std.traits : getUDAs;

import sparkles.wired.policy : Repr, hasExplicitWireName,
    resolvedFieldPolicies;
import sparkles.wired.schema : NodeKind, ScalarKind, WireSchema, wireSchemaOf;

// ── Format marker ────────────────────────────────────────────────────────────

/// The SDL format tag: `wireSchemaOf!(Sdl, T)`, `@WireName!Sdl("ns:name")`, …
struct Sdl
{
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
enum SdlRoleKind : ubyte
{
    child,         /// named child tag (the unannotated default)
    tagValue,      /// positional value of the containing tag
    attribute,     /// named attribute of the containing tag
    tagName,       /// dynamic local-name data field
    tagNamespace,  /// dynamic namespace data field
    extra,         /// ordered unmatched-capture placeholder (SPEC §8)
}

/// How a `child`-role field maps onto child tags (SPEC §5.2).
enum SdlChildShape : ubyte
{
    none,
    scalarSingle,       /// one child whose positional value 0 is the scalar
    aggregateSingle,    /// one named child whose body is the aggregate
    scalarSequence,     /// values appended from every matching occurrence
    aggregateSequence,  /// one sibling child per element
    map,                /// one child per entry keyed by the entry key
}

/** One aggregate field's resolved SDL role — plain schema data (SPEC §5). */
struct SdlFieldRole
{
    size_t fieldIndex;   /// position in `T.tupleof`
    size_t nodeIndex;    /// schema arena index of the field's payload node
    SdlRoleKind role;
    string namespace_;   /// resolved namespace; empty = ordinary SDL name
    string localName;    /// resolved local name (case policy or explicit split)
    size_t positionalIndex = size_t.max; /// `tagValue`: the declared slot
    bool dynamicValueSuffix;             /// `tagValue`: dynamic-array suffix
    bool dynamicName;                    /// `tagName` data field
    bool dynamicNamespace;               /// `tagNamespace` data field
    SdlChildShape childShape = SdlChildShape.none; /// `child` role only
    size_t staticCount;  /// exact positions/attributes for static arrays
}

/** One aggregate's projected SDL roles, keyed by field node index. */
struct SdlAggregateRoles
{
    /// Schema node indices of the fields, parallel to $(LREF roles).
    size_t[] fieldNodeIndices;
    SdlFieldRole[] roles;
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

private Shape shapeAt(in WireSchema s, size_t ni)
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
    case NodeKind.nullAware:
        return shapeAt(s, s.edges[s.nodes[ni].firstEdge]);
    case NodeKind.sequence:
        return shapeElement(s, s.edges[s.nodes[ni].firstEdge], false);
    case NodeKind.staticArray:
        return shapeElement(s, s.edges[s.nodes[ni].firstEdge], true);
    case NodeKind.map:
        return Shape.map;
    case NodeKind.unionType:
    case NodeKind.passthrough:
        return Shape.other;
    }
}

private Shape shapeElement(in WireSchema s, size_t elementIndex, bool)
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
private bool nameBearing(in WireSchema s, size_t ni)
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

/** Splits one explicit `@WireName!Sdl` spelling into namespace and local name.

A colon splits exactly once; empty halves and additional colons are
compile-time errors naming the aggregate and field (SPEC §5.1).
*/
template splitSdlQualifiedName(string aggregate, string field, string raw)
{
    static if (raw.length == 0)
    {
        static assert(false, "wired.sdl: " ~ aggregate ~ "." ~ field
            ~ ": qualified SDL name must not be empty");
        enum namespace_ = null;
        enum localName = null;
    }
    else
    {
        private enum firstColon = () {
            foreach (i, c; raw)
                if (c == ':')
                    return cast(ptrdiff_t) i;
            return cast(ptrdiff_t) -1;
        }();
        private enum lastColon = () {
            ptrdiff_t found = -1;
            foreach (i, c; raw)
                if (c == ':')
                    found = i;
            return found;
        }();
        static if (firstColon < 0)
        {
            enum namespace_ = null;
            enum localName = raw;
        }
        else static if (firstColon != lastColon)
        {
            static assert(false, "wired.sdl: " ~ aggregate ~ "." ~ field
                ~ ": qualified SDL name \"" ~ raw
                ~ "\" must contain exactly one ':'");
            enum namespace_ = null;
            enum localName = null;
        }
        else static if (firstColon == 0 || lastColon == raw.length - 1)
        {
            static assert(false, "wired.sdl: " ~ aggregate ~ "." ~ field
                ~ ": qualified SDL name \"" ~ raw
                ~ "\" must not have an empty namespace or local half");
            enum namespace_ = null;
            enum localName = null;
        }
        else
        {
            enum namespace_ = raw[0 .. firstColon];
            enum localName = raw[firstColon + 1 .. $];
        }
    }
}

// ── The SDL projection ───────────────────────────────────────────────────────

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
    * when `isDocumentRoot`, dynamic identity fields are forbidden on the root
    aggregate.
)
*/
template sdlAggregateRoles(T, bool isDocumentRoot = false)
if (is(T == struct))
{
    import std.meta : AliasSeq;

    private enum schema = wireSchemaOf!(Sdl, T);
    static assert(schema.nodes[0].kind == NodeKind.aggregate,
        "wired.sdl: " ~ T.stringof
        ~ ": SDL document root must be an unconverted aggregate");

    private alias policies = resolvedFieldPolicies!(Sdl, T);
    private enum fieldCount = policies.length;

    // Per-field compile-time facts, gathered once for both validation and
    // sidecar construction.
    template FieldFacts(alias symbol, size_t i)
    {
        enum ident = __traits(identifier, symbol);
        enum ni = schema.edges[schema.nodes[0].firstEdge + i];

        enum tagValueCount = getUDAs!(symbol, SdlTagValueAttr).length;
        enum attributeCount = getUDAs!(symbol, SdlAttributeAttr).length;
        enum childCount = getUDAs!(symbol, SdlChildAttr).length;
        enum tagNameCount = getUDAs!(symbol, SdlTagNameAttr).length;
        enum tagNamespaceCount = getUDAs!(symbol, SdlTagNamespaceAttr).length;
        enum extraCount = getUDAs!(symbol, SdlExtraAttr).length;
        enum roleCount = tagValueCount + attributeCount + childCount
            + tagNameCount + tagNamespaceCount + extraCount;

        static if (tagValueCount)
            enum SdlRoleKind role = SdlRoleKind.tagValue;
        else static if (attributeCount)
            enum SdlRoleKind role = SdlRoleKind.attribute;
        else static if (tagNameCount)
            enum SdlRoleKind role = SdlRoleKind.tagName;
        else static if (tagNamespaceCount)
            enum SdlRoleKind role = SdlRoleKind.tagNamespace;
        else static if (extraCount)
            enum SdlRoleKind role = SdlRoleKind.extra;
        else
            enum SdlRoleKind role = SdlRoleKind.child;

        static if (tagValueCount)
            enum size_t declaredIndex = getUDAs!(symbol, SdlTagValueAttr)[0]
                .index;
        else
            enum size_t declaredIndex = size_t.max;

        static if (role == SdlRoleKind.child
            || role == SdlRoleKind.tagValue
            || role == SdlRoleKind.attribute)
        {
            enum Shape shape = shapeAt(schema, ni);
        }
        else
            enum Shape shape = Shape.other;

        private enum size_t staticLength = schema.nodes[ni].kind
            == NodeKind.reference
            ? schema.nodes[schema.nodes[ni].referenceIndex].staticLength
            : schema.nodes[ni].staticLength;

        /// Whether the wrapper itself is a runtime-length array (the marker
        /// distinguishing a dynamic value-suffix sequence from a static one).
        enum bool dynamicArrayWrapper = (schema.nodes[ni].kind
                == NodeKind.reference
            ? schema.nodes[schema.nodes[ni].referenceIndex].kind
            : schema.nodes[ni].kind) == NodeKind.sequence;
    }

    // ── §5.2 validation ──────────────────────────────────────────────────
    private enum validationError = () {
        string err;
        int tagNameSeen, tagNsSeen, extraSeen;
        string dynamicNameAt, dynamicNsAt;
        size_t[] occupied;
        bool hasDynamicSuffix;
        size_t dynamicIndex;
        bool anyFixedIndex;
        size_t maxFixedIndex;

        static void occupy(ref string err, ref size_t[] taken,
            size_t from, size_t count, string where_)
        {
            foreach (p; from .. from + count)
            {
                foreach (existing; taken)
                    if (existing == p)
                    {
                        import std.conv : to;

                        err ~= "wired.sdl: " ~ T.stringof ~ "." ~ where_
                            ~ ": positional value slot " ~ p.to!string
                            ~ " is already claimed by another"
                            ~ " @SdlTagValue field";
                        return;
                    }
                taken ~= p;
            }
        }

        static foreach (i; 0 .. fieldCount)
        {{
            alias F = FieldFacts!(T.tupleof[i], i);

            static if (F.roleCount > 1)
                err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                    ~ ": a field declares at most one SDL role UDA";

            final switch (F.role)
            {
            case SdlRoleKind.child:
                final switch (F.shape)
                {
                case Shape.scalarSingle:
                case Shape.aggregateSingle:
                case Shape.seqScalar:
                case Shape.seqAggregate:
                case Shape.map:
                    break;
                case Shape.other:
                    err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                        ~ ": @SdlChild requires a scalar, an aggregate, a "
                        ~ "scalar or aggregate sequence/static array, or a "
                        ~ "map with string/enum keys";
                    break;
                }
                static if (F.shape == Shape.map)
                {{
                    const mapTarget = schema.nodes[F.ni].kind
                        == NodeKind.reference
                        ? schema.nodes[F.ni].referenceIndex : F.ni;
                    const keyNode = schema.edges[
                        schema.nodes[mapTarget].firstEdge];
                    if (!nameBearing(schema, keyNode))
                        err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                            ~ ": an associative-array @SdlChild requires "
                            ~ "string or name-represented enum keys";
                }}
                break;
            case SdlRoleKind.tagValue:
                final switch (F.shape)
                {
                case Shape.scalarSingle:
                    maxFixedIndex = anyFixedIndex
                        && maxFixedIndex > F.declaredIndex
                        ? maxFixedIndex : F.declaredIndex;
                    anyFixedIndex = true;
                    occupy(err, occupied, F.declaredIndex, 1, F.ident);
                    break;
                case Shape.seqScalar:
                    static if (F.dynamicArrayWrapper)
                    {
                        if (!hasDynamicSuffix)
                        {
                            hasDynamicSuffix = true;
                            dynamicIndex = F.declaredIndex;
                        }
                        else
                            err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                                ~ ": at most one dynamic @SdlTagValue "
                                ~ "sequence may consume a suffix per aggregate";
                    }
                    else
                    {
                        const staticEnd = F.declaredIndex + F.staticLength - 1;
                        maxFixedIndex = anyFixedIndex
                            && maxFixedIndex > staticEnd
                            ? maxFixedIndex : staticEnd;
                        anyFixedIndex = true;
                        occupy(err, occupied, F.declaredIndex, F.staticLength,
                            F.ident);
                    }
                    break;
                case Shape.aggregateSingle:
                case Shape.seqAggregate:
                case Shape.map:
                case Shape.other:
                    err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                        ~ ": @SdlTagValue requires a scalar-convertible "
                        ~ "field or a sequence/static array of them";
                    break;
                }
                break;
            case SdlRoleKind.attribute:
                final switch (F.shape)
                {
                case Shape.scalarSingle:
                case Shape.seqScalar:
                    break;
                case Shape.aggregateSingle:
                case Shape.seqAggregate:
                case Shape.map:
                case Shape.other:
                    err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                        ~ ": @SdlAttribute must be scalar-convertible "
                        ~ "(a sequence means repeated attributes); nested "
                        ~ "aggregates and maps are unsupported";
                    break;
                }
                break;
            case SdlRoleKind.tagName:
                tagNameSeen++;
                dynamicNameAt = F.ident;
                if (!nameBearing(schema, F.ni))
                    err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                        ~ ": @SdlTagName requires a string or "
                        ~ "name-represented enum field";
                break;
            case SdlRoleKind.tagNamespace:
                tagNsSeen++;
                dynamicNsAt = F.ident;
                if (!nameBearing(schema, F.ni))
                    err ~= "wired.sdl: " ~ T.stringof ~ "." ~ F.ident
                        ~ ": @SdlTagNamespace requires a string or "
                        ~ "name-represented enum field";
                break;
            case SdlRoleKind.extra:
                extraSeen++;
                break;
            }
        }}

        if (tagNameSeen > 1)
            err ~= "wired.sdl: " ~ T.stringof
                ~ ": at most one @SdlTagName field per aggregate";
        if (tagNsSeen > 1)
            err ~= "wired.sdl: " ~ T.stringof
                ~ ": at most one @SdlTagNamespace field per aggregate";
        if (extraSeen > 1)
            err ~= "wired.sdl: " ~ T.stringof
                ~ ": at most one @SdlExtra field per aggregate";
        // With no fixed slots at all, index 0 *is* the greatest declared
        // index; comparing against a zero-initialized `maxFixedIndex` rejects
        // the most natural positional shape there is (`tag "a" "b" "c"`).
        if (hasDynamicSuffix && anyFixedIndex && dynamicIndex <= maxFixedIndex)
            err ~= "wired.sdl: " ~ T.stringof
                ~ ": the dynamic @SdlTagValue sequence must have the "
                ~ "greatest declared index";
        static if (isDocumentRoot)
        {
            if (dynamicNameAt.length)
                err ~= "wired.sdl: " ~ T.stringof ~ "." ~ dynamicNameAt
                    ~ ": @SdlTagName is forbidden on synthetic document roots";
            if (dynamicNsAt.length)
                err ~= "wired.sdl: " ~ T.stringof ~ "." ~ dynamicNsAt
                    ~ ": @SdlTagNamespace is forbidden on synthetic document roots";
        }
        return err;
    }();
    static assert(validationError.length == 0, validationError);

    /// The projected roles, parallel to the aggregate's declared fields.
    static immutable SdlAggregateRoles sdlFieldRoles = () {
        SdlAggregateRoles result;
        static foreach (i; 0 .. fieldCount)
        {{
            alias F = FieldFacts!(T.tupleof[i], i);
            SdlFieldRole role;
            role.fieldIndex = i;
            role.nodeIndex = F.ni;
            role.role = F.role;

            static if (hasExplicitWireName!(Sdl, T.tupleof[i]))
            {
                role.namespace_ = splitSdlQualifiedName!(T.stringof,
                    F.ident, policies[i].key).namespace_;
                role.localName = splitSdlQualifiedName!(T.stringof,
                    F.ident, policies[i].key).localName;
            }
            else
            {
                role.namespace_ = null;
                role.localName = policies[i].key;
            }

            final switch (F.role)
            {
            case SdlRoleKind.tagValue:
                role.positionalIndex = F.declaredIndex;
                role.dynamicValueSuffix = F.shape == Shape.seqScalar
                    && F.dynamicArrayWrapper;
                role.staticCount = F.staticLength;
                break;
            case SdlRoleKind.tagName:
                role.dynamicName = true;
                break;
            case SdlRoleKind.tagNamespace:
                role.dynamicNamespace = true;
                break;
            case SdlRoleKind.child:
                final switch (F.shape)
                {
                case Shape.scalarSingle:
                    role.childShape = SdlChildShape.scalarSingle;
                    break;
                case Shape.aggregateSingle:
                    role.childShape = SdlChildShape.aggregateSingle;
                    break;
                case Shape.seqScalar:
                    role.childShape = SdlChildShape.scalarSequence;
                    role.staticCount = F.staticLength;
                    break;
                case Shape.seqAggregate:
                    role.childShape = SdlChildShape.aggregateSequence;
                    break;
                case Shape.map:
                    role.childShape = SdlChildShape.map;
                    break;
                case Shape.other:
                    assert(false);
                }
                break;
            case SdlRoleKind.attribute:
                role.staticCount = F.staticLength;
                break;
            case SdlRoleKind.extra:
                break;
            }
            result.fieldNodeIndices ~= F.ni;
            result.roles ~= role;
        }}
        return result;
    }();

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
        @SdlExtra() int extras;
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
        int extras;
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
        @SdlExtra() int extras;
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

    static struct MultipleRolesOneField
    {
        @SdlChild() @SdlAttribute() int ambiguous;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!MultipleRolesOneField));
}
