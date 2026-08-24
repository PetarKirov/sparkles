/**
Compile-time wire-schema reification.

`wireSchemaOf!(F, T)` lowers the currently supported wired type vocabulary to
plain data. Nodes and child edges are flat arenas; recursive re-entry is an
explicit `NodeKind.reference` node whose `referenceIndex` names an earlier
node. Policy values are resolved through `sparkles.wired.policy`, once, while
the arena is built.

`fieldPolicies` is a compatibility projection of aggregate child snapshots.
The builder consumes the declaration-only policy seed, avoiding a
policy/schema template cycle.
*/
module sparkles.wired.schema;

import std.datetime.systime : SysTime;
import std.json : JSONValue;
import std.sumtype : isSumType;
import std.traits : isAssociativeArray, isDynamicArray, isFloatingPoint,
    isIntegral, isSomeChar, isStaticArray, OriginalType, TemplateArgsOf, Unqual;
import std.typecons : Nullable, Ternary;

import optional : Optional;

import sparkles.wired.policy;

/// Structural node vocabulary shared by format walkers and derivations.
enum NodeKind : ubyte
{
    scalar,
    enumeration,
    aggregate,
    unionType,
    sequence,
    staticArray,
    map,
    nullAware,
    converted,
    passthrough,
    reference,
}

/// Scalar distinctions which can affect a format's wire representation.
enum ScalarKind : ubyte
{
    none,
    boolean,
    signedInteger,
    unsignedInteger,
    floating,
    character,
    string,
    sysTime,
}

/// The three null-aware wrapper families supported by wired.
enum NullAwareKind : ubyte
{
    none,
    nullable,
    optional,
    ternary,
}

/** A resolved copy of the current policy at one schema node.

`field` preserves the complete base-policy table entry. `caseStyle` and `repr`
finish its slot lattice against the reached node's type policy, so consumers do
not need to query declarations again.
*/
struct PolicySnapshot
{
    FieldPolicy field;
    CaseStyle caseStyle = CaseStyle.original;
    Repr repr = Repr.name;
}

/// One attached D UDA preserved as CTFE data for format-specific consumers.
struct SchemaAnnotation
{
    string typeName; /// annotation type (or template/type UDA spelling)
    string value;    /// CTFE spelling of the attached value
}

/// One cell in a $(LREF WireSchema) node arena.
struct SchemaNode
{
    NodeKind kind;
    ScalarKind scalarKind;
    ushort scalarBits; /// scalar storage width where it constrains wire values
    NullAwareKind nullAwareKind;
    string typeName;       /// diagnostic D type name; excluded from the digest
    string name;           /// field key, enum-member name, or union variant name
    string enumValue;      /// enum member's underlying value descriptor
    bool nameAffectsWire;  /// whether `name` participates in the digest
    bool enumValueAffectsWire; /// whether `enumValue` participates in the digest
    size_t firstEdge;      /// range in `WireSchema.edges`
    size_t edgeCount;      /// ditto
    size_t referenceIndex = size_t.max; /// target for `reference`
    size_t staticLength;   /// `T[N]` length, zero otherwise
    size_t firstAnnotation;
    size_t annotationCount;
    PolicySnapshot policy;
}

/** Flat compile-time schema arena. Node zero is always the root.

`edges[node.firstEdge .. node.firstEdge + node.edgeCount]` contains child node
indices. Annotation ranges use the same extent convention.
*/
struct WireSchema
{
    SchemaNode[] nodes;
    size_t[] edges;
    SchemaAnnotation[] annotations;
    string[] names; /// interned wire-visible names, in first-seen order
}

private enum bool isExpectedLike(X) =
    __traits(hasMember, X, "hasValue") && __traits(hasMember, X, "hasError")
    && __traits(hasMember, X, "value") && __traits(hasMember, X, "error");

private enum bool isNullAwareType(T) = is(T == Nullable!N, N)
    || is(T == Optional!O, O) || is(T == Ternary);

private template ancestorPosition(T, Ancestors...)
{
    enum ptrdiff_t ancestorPosition = () {
        static foreach (i, A; Ancestors)
            static if (is(T == A))
                return cast(ptrdiff_t) i;
        return cast(ptrdiff_t)(-1);
    }();
}

private string annotationType(alias uda)()
{
    static if (is(uda))
        return uda.stringof;
    else
        return typeof(uda).stringof;
}

private string annotationValue(alias uda)()
{
    return uda.stringof;
}

private string[] resolvedWireNames(F, E)(CaseStyle style)
if (is(E == enum))
{
    final switch (style)
    {
        static foreach (candidate; __traits(allMembers, CaseStyle))
        {
            case __traits(getMember, CaseStyle, candidate):
                return wireNames!(F, E,
                    __traits(getMember, CaseStyle, candidate)).dup;
        }
    }
}

private string enumValueText(T)(T value)
{
    import std.conv : to;

    return value.to!string;
}

private WireSchema buildWireSchema(F, T)()
{
    WireSchema schema;

    void internName(string name)
    {
        if (name.length == 0)
            return;
        foreach (known; schema.names)
            if (known == name)
                return;
        schema.names ~= name;
    }

    void appendAnnotations(alias symbol)(size_t nodeIndex)
    {
        if (schema.nodes[nodeIndex].annotationCount == 0)
            schema.nodes[nodeIndex].firstAnnotation = schema.annotations.length;
        static foreach (uda; __traits(getAttributes, symbol))
            schema.annotations ~= SchemaAnnotation(
                annotationType!uda, annotationValue!uda);
        schema.nodes[nodeIndex].annotationCount =
            schema.annotations.length - schema.nodes[nodeIndex].firstAnnotation;
    }

    void appendFieldAnnotations(Parent, size_t fieldIndex)(size_t nodeIndex)
    {
        if (schema.nodes[nodeIndex].annotationCount == 0)
            schema.nodes[nodeIndex].firstAnnotation = schema.annotations.length;
        static foreach (uda; __traits(getAttributes, Parent.tupleof[fieldIndex]))
            schema.annotations ~= SchemaAnnotation(
                annotationType!uda, annotationValue!uda);
        schema.nodes[nodeIndex].annotationCount =
            schema.annotations.length - schema.nodes[nodeIndex].firstAnnotation;
    }

    size_t appendNode(NodeKind kind, string typeName, string name,
        FieldPolicy fieldPolicy)
    {
        SchemaNode node;
        node.kind = kind;
        node.typeName = typeName;
        node.name = name;
        node.nameAffectsWire = name.length != 0;
        node.policy.field = fieldPolicy;
        schema.nodes ~= node;
        internName(name);
        return schema.nodes.length - 1;
    }

    size_t reserveEdges(size_t nodeIndex, size_t count)
    {
        const first = schema.edges.length;
        schema.edges.length += count;
        schema.nodes[nodeIndex].firstEdge = first;
        schema.nodes[nodeIndex].edgeCount = count;
        return first;
    }

    size_t buildShape(U, Ancestors...)(string name, FieldPolicy site,
        WireTarget slot, size_t[] ancestorIndices)
    {
        alias V = Unqual!U;
        enum prior = ancestorPosition!(V, Ancestors);
        static if (prior >= 0)
        {
            const index = appendNode(NodeKind.reference, V.stringof, name, site);
            schema.nodes[index].referenceIndex = ancestorIndices[prior];
            return index;
        }
        else
        {
            const index = appendNode(NodeKind.scalar, V.stringof, name, site);
            size_t[] nextAncestors = ancestorIndices.dup;
            nextAncestors ~= index;

            static if (is(V == JSONValue))
                schema.nodes[index].kind = NodeKind.passthrough;
            else static if (is(V == bool))
            {
                schema.nodes[index].scalarKind = ScalarKind.boolean;
                schema.nodes[index].scalarBits = 1;
            }
            else static if (is(V == string))
            {
                schema.nodes[index].scalarKind = ScalarKind.string;
                schema.nodes[index].scalarBits = 8;
            }
            else static if (isSomeChar!V)
            {
                schema.nodes[index].scalarKind = ScalarKind.character;
                schema.nodes[index].scalarBits = V.sizeof * 8;
            }
            else static if (is(V == enum))
            {
                schema.nodes[index].kind = NodeKind.enumeration;
                schema.nodes[index].policy.caseStyle = site.caseFor(
                    slot, resolveCaseStyle!(F, V));
                schema.nodes[index].policy.repr = site.reprFor(
                    slot, resolveRepr!(F, V));
                static if (isIntegral!(OriginalType!V))
                {
                    schema.nodes[index].scalarKind =
                        __traits(isUnsigned, OriginalType!V)
                        ? ScalarKind.unsignedInteger : ScalarKind.signedInteger;
                    schema.nodes[index].scalarBits = OriginalType!V.sizeof * 8;
                }
                else static if (isFloatingPoint!(OriginalType!V))
                {
                    schema.nodes[index].scalarKind = ScalarKind.floating;
                    schema.nodes[index].scalarBits = OriginalType!V.sizeof * 8;
                }
                else static if (isSomeChar!(OriginalType!V))
                {
                    schema.nodes[index].scalarKind = ScalarKind.character;
                    schema.nodes[index].scalarBits = OriginalType!V.sizeof * 8;
                }
                else static if (is(OriginalType!V == string))
                {
                    schema.nodes[index].scalarKind = ScalarKind.string;
                    schema.nodes[index].scalarBits = 8;
                }
                const memberNames = resolvedWireNames!(F, V)(
                    schema.nodes[index].policy.caseStyle);
                const first = reserveEdges(index, memberNames.length);
                static foreach (i, member; __traits(allMembers, V))
                {{
                    FieldPolicy memberPolicy;
                    memberPolicy.key = memberNames[i];
                    const child = appendNode(NodeKind.scalar,
                        OriginalType!V.stringof, memberNames[i], memberPolicy);
                    schema.nodes[child].enumValue = enumValueText(
                        cast(OriginalType!V) __traits(getMember, V, member));
                    schema.nodes[child].nameAffectsWire =
                        schema.nodes[index].policy.repr == Repr.name;
                    schema.nodes[child].enumValueAffectsWire =
                        schema.nodes[index].policy.repr == Repr.value;
                    appendAnnotations!(__traits(getMember, V, member))(child);
                    schema.edges[first + i] = child;
                }}
            }
            else static if (isIntegral!V)
            {
                schema.nodes[index].scalarKind = __traits(isUnsigned, V)
                    ? ScalarKind.unsignedInteger : ScalarKind.signedInteger;
                schema.nodes[index].scalarBits = V.sizeof * 8;
            }
            else static if (isFloatingPoint!V)
            {
                schema.nodes[index].scalarKind = ScalarKind.floating;
                schema.nodes[index].scalarBits = V.sizeof * 8;
            }
            else static if (is(V == SysTime))
                schema.nodes[index].scalarKind = ScalarKind.sysTime;
            else static if (isStaticArray!V)
            {
                alias E = typeof(V.init[0]);
                schema.nodes[index].kind = NodeKind.staticArray;
                schema.nodes[index].staticLength = V.length;
                const first = reserveEdges(index, 1);
                const child = buildShape!(E, Ancestors, V)("", site,
                    WireTarget.value, nextAncestors);
                schema.edges[first] = child;
            }
            else static if (is(V == CharElement[], CharElement)
                && isSomeChar!CharElement)
            {
                schema.nodes[index].scalarKind = ScalarKind.string;
                schema.nodes[index].scalarBits = CharElement.sizeof * 8;
            }
            else static if (isDynamicArray!V)
            {
                alias E = typeof(V.init[0]);
                schema.nodes[index].kind = NodeKind.sequence;
                const first = reserveEdges(index, 1);
                const child = buildShape!(E, Ancestors, V)("", site,
                    WireTarget.value, nextAncestors);
                schema.edges[first] = child;
            }
            else static if (isAssociativeArray!V)
            {
                alias K = typeof(V.init.keys[0]);
                alias E = typeof(V.init.values[0]);
                schema.nodes[index].kind = NodeKind.map;
                const first = reserveEdges(index, 2);
                const keyChild = buildShape!(K, Ancestors, V)("", site,
                    WireTarget.key, nextAncestors);
                schema.edges[first] = keyChild;
                const valueChild = buildShape!(E, Ancestors, V)("", site,
                    WireTarget.value, nextAncestors);
                schema.edges[first + 1] = valueChild;
            }
            else static if (is(V == Nullable!N, N))
            {
                static assert(!isNullAwareType!N,
                    "wired: nested null-aware wrappers are unsupported: " ~ V.stringof);
                schema.nodes[index].kind = NodeKind.nullAware;
                schema.nodes[index].nullAwareKind = NullAwareKind.nullable;
                const first = reserveEdges(index, 1);
                const child = buildShape!(N, Ancestors, V)("", site,
                    WireTarget.value, nextAncestors);
                schema.edges[first] = child;
            }
            else static if (is(V == Optional!N, N))
            {
                static assert(!isNullAwareType!N,
                    "wired: nested null-aware wrappers are unsupported: " ~ V.stringof);
                schema.nodes[index].kind = NodeKind.nullAware;
                schema.nodes[index].nullAwareKind = NullAwareKind.optional;
                const first = reserveEdges(index, 1);
                const child = buildShape!(N, Ancestors, V)("", site,
                    WireTarget.value, nextAncestors);
                schema.edges[first] = child;
            }
            else static if (is(V == Ternary))
            {
                schema.nodes[index].kind = NodeKind.nullAware;
                schema.nodes[index].nullAwareKind = NullAwareKind.ternary;
            }
            else static if (isSumType!V)
            {
                schema.nodes[index].kind = NodeKind.unionType;
                alias Variants = TemplateArgsOf!V;
                const first = reserveEdges(index, Variants.length);
                static foreach (i, Variant; Variants)
                {{
                    const child = buildShape!(Variant, Ancestors, V)(
                        Variant.stringof, site, slot, nextAncestors);
                    schema.nodes[child].nameAffectsWire = false;
                    schema.edges[first + i] = child;
                }}
            }
            else static if (is(V == struct))
            {
                schema.nodes[index].kind = NodeKind.aggregate;
                schema.nodes[index].policy.caseStyle = site.caseFor(
                    slot, resolveCaseStyle!(F, V));
                alias policies = resolvedFieldPolicies!(F, V);
                const first = reserveEdges(index, policies.length);
                static foreach (i; 0 .. policies.length)
                {{
                    alias E = typeof(V.tupleof[i]);
                    FieldPolicy field = policies[i];
                    static if (!hasExplicitWireName!(F, V.tupleof[i]))
                        field.key = convertCaseOf(
                            schema.nodes[index].policy.caseStyle,
                            __traits(identifier, V.tupleof[i]));
                    const child = buildField!(V, i, E,
                        Ancestors, V)(field.key, field, nextAncestors);
                    schema.edges[first + i] = child;
                }}
                foreach (i; 0 .. policies.length)
                    foreach (j; 0 .. i)
                    {
                        const a = schema.nodes[schema.edges[first + i]].name;
                        const b = schema.nodes[schema.edges[first + j]].name;
                        assert(a != b, "wired: duplicate field key \"" ~ a
                            ~ "\" for " ~ V.stringof ~ " under format "
                            ~ F.stringof);
                    }
            }
            else
                static assert(false, "wired: unsupported schema type " ~ V.stringof
                    ~ " under format " ~ F.stringof);
            return index;
        }
    }

    size_t buildConverted(alias Conv, U, Ancestors...)(string name,
        FieldPolicy site, size_t[] ancestorIndices)
    {
        alias Raw = typeof(Conv.to(U.init));
        static if (isExpectedLike!Raw)
            alias WireType = typeof(Raw.init.value);
        else
            alias WireType = Raw;
        const index = appendNode(NodeKind.converted, U.stringof, name, site);
        const first = reserveEdges(index, 1);
        FieldPolicy wirePolicy;
        const child = buildType!(WireType, Ancestors)("", wirePolicy,
            WireTarget.all, ancestorIndices);
        schema.edges[first] = child;
        return index;
    }

    size_t buildType(U, Ancestors...)(string name, FieldPolicy site,
        WireTarget slot, size_t[] ancestorIndices)
    {
        static if (hasConvert!(F, U))
        {
            const index = buildConverted!(convertOf!(F, U), U, Ancestors)(
                name, site, ancestorIndices);
            appendAnnotations!U(index);
            return index;
        }
        else
        {
            const index = buildShape!(U, Ancestors)(name, site, slot, ancestorIndices);
            appendAnnotations!U(index);
            return index;
        }
    }

    size_t buildField(Parent, size_t fieldIndex, U, Ancestors...)(string name,
        FieldPolicy site, size_t[] ancestorIndices)
    {
        static if (hasConvert!(F, Parent.tupleof[fieldIndex], U))
        {
            const index = buildConverted!(
                convertOf!(F, Parent.tupleof[fieldIndex], U), U, Ancestors)(
                name, site, ancestorIndices);
            appendAnnotations!U(index);
            appendFieldAnnotations!(Parent, fieldIndex)(index);
            return index;
        }
        else
        {
            const index = buildShape!(U, Ancestors)(name, site,
                WireTarget.all, ancestorIndices);
            appendAnnotations!U(index);
            appendFieldAnnotations!(Parent, fieldIndex)(index);
            return index;
        }
    }

    FieldPolicy rootPolicy;
    size_t[] noAncestors;
    const root = buildType!T("", rootPolicy, WireTarget.all, noAncestors);
    assert(root == 0);
    return schema;
}

/// Complete CTFE schema of `T` under format `F`.
template wireSchemaOf(F, T)
{
    enum WireSchema wireSchemaOf = buildWireSchema!(F, T)();
}

/** Projects an aggregate root's schema children back to the current flat API.

The declaration-only seed used while building the schema keeps this projection
acyclic.
*/
template schemaFieldPolicies(F, T)
if (is(T == struct))
{
    enum schema = wireSchemaOf!(F, T);
    static assert(schema.nodes[0].kind == NodeKind.aggregate,
        "wired: schemaFieldPolicies requires an unconverted aggregate root");
    static immutable FieldPolicy[] schemaFieldPolicies = () {
        FieldPolicy[] result;
        foreach (edge; schema.edges[
                schema.nodes[0].firstEdge ..
                schema.nodes[0].firstEdge + schema.nodes[0].edgeCount])
            result ~= schema.nodes[edge].policy.field;
        return result;
    }();
}

private ulong digestBytes(ulong hash, scope const(char)[] bytes)
    @safe pure nothrow @nogc
{
    foreach (b; bytes)
    {
        hash ^= cast(ubyte) b;
        hash *= 1_099_511_628_211UL;
    }
    return hash;
}

private ulong digestSize(ulong hash, ulong value) @safe pure nothrow @nogc
{
    foreach (_; 0 .. ulong.sizeof)
    {
        hash ^= cast(ubyte) value;
        hash *= 1_099_511_628_211UL;
        value >>= 8;
    }
    return hash;
}

private ulong digestString(ulong hash, scope const(char)[] value)
    @safe pure nothrow @nogc
{
    return digestBytes(digestSize(hash, value.length), value);
}

private string schemaDigest(in WireSchema schema)
{
    ulong hash = 14_695_981_039_346_656_037UL;
    foreach (node; schema.nodes)
    {
        hash = digestSize(hash, node.kind);
        const scalarAffectsWire = node.kind != NodeKind.enumeration
            || node.policy.repr == Repr.value;
        hash = digestSize(hash, scalarAffectsWire ? node.scalarKind : ScalarKind.none);
        hash = digestSize(hash, scalarAffectsWire ? node.scalarBits : 0);
        hash = digestSize(hash, node.nullAwareKind);
        if (node.nameAffectsWire)
            hash = digestString(hash, node.name);
        else
            hash = digestSize(hash, 0);
        if (node.enumValueAffectsWire)
            hash = digestString(hash, node.enumValue);
        else
            hash = digestSize(hash, 0);
        hash = digestSize(hash, node.kind == NodeKind.reference
            ? node.referenceIndex : 0);
        hash = digestSize(hash, node.staticLength);
        hash = digestSize(hash, node.policy.field.optional);
        hash = digestSize(hash, node.policy.field.skip);
        hash = digestSize(hash, node.policy.field.onInvalid);
        hash = digestSize(hash, node.policy.field.match);
        hash = digestSize(hash, node.policy.repr);
        hash = digestSize(hash, node.edgeCount);
    }
    foreach (edge; schema.edges)
        hash = digestSize(hash, edge);

    char[16] result;
    foreach_reverse (i; 0 .. result.length)
    {
        result[i] = "0123456789abcdef"[hash & 0xF];
        hash >>= 4;
    }
    return result.idup;
}

/// Stable hexadecimal digest of a schema's wire-visible surface.
template wireSchemaDigest(F, T)
{
    enum string wireSchemaDigest = schemaDigest(wireSchemaOf!(F, T));
}

version (unittest)
{
    import std.sumtype : SumType;

    import sparkles.wired.json : Json;

    private struct OtherFormat
    {
    }

    private struct OpenAnnotation
    {
        string text;
    }
}

@("wired.schema.scalarsAndEnums")
@safe pure unittest
{
    import std.meta : AliasSeq;

    alias Scalars = AliasSeq!(bool, char, wchar, dchar, byte, ushort, int,
        long, ulong, float, double, string, SysTime);
    static foreach (Scalar; Scalars)
    {{
        enum scalar = wireSchemaOf!(Json, Scalar);
        static assert(scalar.nodes.length == 1);
        static assert(scalar.nodes[0].kind == NodeKind.scalar);
        static assert(scalar.nodes[0].scalarKind != ScalarKind.none);
    }}
    enum passthrough = wireSchemaOf!(Json, JSONValue);
    static assert(passthrough.nodes[0].kind == NodeKind.passthrough);

    @WireCase!Json(CaseStyle.snakeCase)
    enum Mode { fastPath, @WireName!Json("turbo") slowPath }
    enum members = wireSchemaOf!(Json, Mode);
    static assert(members.nodes[0].kind == NodeKind.enumeration);
    static assert(members.nodes[members.edges[0]].name == "fast_path");
    static assert(members.nodes[members.edges[1]].name == "turbo");
}

@("wired.schema.aggregatesArraysAndMaps")
@safe pure unittest
{
    static struct Item { int value; }
    static struct Shape
    {
        Item[] dynamicItems;
        int[3] fixedItems;
        Item[string] indexedItems;
    }
    enum schema = wireSchemaOf!(Json, Shape);
    static assert(schema.nodes[0].kind == NodeKind.aggregate);
    enum dynamicNode = schema.edges[schema.nodes[0].firstEdge];
    enum fixedNode = schema.edges[schema.nodes[0].firstEdge + 1];
    enum mapNode = schema.edges[schema.nodes[0].firstEdge + 2];
    static assert(schema.nodes[dynamicNode].kind == NodeKind.sequence);
    static assert(schema.nodes[fixedNode].kind == NodeKind.staticArray);
    static assert(schema.nodes[fixedNode].staticLength == 3);
    static assert(schema.nodes[mapNode].kind == NodeKind.map);
    static assert(schema.nodes[mapNode].edgeCount == 2);
}

@("wired.schema.nullAwareAndSumType")
@safe pure unittest
{
    static struct Shape
    {
        Nullable!int nullable;
        Optional!string optional;
        Ternary ternary;
        SumType!(int, string) choice;
    }
    enum schema = wireSchemaOf!(Json, Shape);
    enum root = schema.nodes[0];
    static assert(schema.nodes[schema.edges[root.firstEdge]].nullAwareKind
        == NullAwareKind.nullable);
    static assert(schema.nodes[schema.edges[root.firstEdge + 1]].nullAwareKind
        == NullAwareKind.optional);
    static assert(schema.nodes[schema.edges[root.firstEdge + 2]].nullAwareKind
        == NullAwareKind.ternary);
    static assert(schema.nodes[schema.edges[root.firstEdge + 3]].kind
        == NodeKind.unionType);
}

@("wired.schema.converterBoundary")
@safe pure unittest
{
    static struct Shape
    {
        @WireConvert!(v => cast(long) v, v => cast(int) v)
        int converted;
    }
    enum schema = wireSchemaOf!(Json, Shape);
    enum converted = schema.edges[schema.nodes[0].firstEdge];
    static assert(schema.nodes[converted].kind == NodeKind.converted);
    enum wireNode = schema.edges[schema.nodes[converted].firstEdge];
    static assert(schema.nodes[wireNode].scalarKind == ScalarKind.signedInteger);
    static assert(schema.nodes[wireNode].typeName == "long");
}

@("wired.schema.recursionUsesReferenceNode")
@safe pure unittest
{
    static struct Tree
    {
        string label;
        Tree[] children;
    }
    enum schema = wireSchemaOf!(Json, Tree);
    enum children = schema.edges[schema.nodes[0].firstEdge + 1];
    enum child = schema.edges[schema.nodes[children].firstEdge];
    static assert(schema.nodes[child].kind == NodeKind.reference);
    static assert(schema.nodes[child].referenceIndex == 0);
}

@("wired.schema.formatNamingAndPolicyProjection")
@safe pure unittest
{
    @WireCase!Json(CaseStyle.snakeCase)
    @WireCase!OtherFormat(CaseStyle.kebabCase)
    static struct Shape
    {
        @WireOptional(WireSkip.whenDefault, WireInvalid.useDefault)
        int fieldName;
    }
    enum json = wireSchemaOf!(Json, Shape);
    enum other = wireSchemaOf!(OtherFormat, Shape);
    static assert(json.nodes[json.edges[0]].name == "field_name");
    static assert(other.nodes[other.edges[0]].name == "field-name");
    static assert(schemaFieldPolicies!(Json, Shape) == fieldPolicies!(Json, Shape));
}

@("wired.schema.wrapperSlotsResolvePerNode")
@safe pure unittest
{
    enum Key { first, second }
    enum Value { low, high }
    static struct Shape
    {
        @WireRepr!Json(Repr.value, WireTarget.key)
        @WireCase!Json(CaseStyle.screamingSnakeCase, WireTarget.value)
        Value[Key][] entries;
    }
    enum schema = wireSchemaOf!(Json, Shape);
    enum sequence = schema.edges[schema.nodes[0].firstEdge];
    enum map = schema.edges[schema.nodes[sequence].firstEdge];
    enum key = schema.edges[schema.nodes[map].firstEdge];
    enum value = schema.edges[schema.nodes[map].firstEdge + 1];
    static assert(schema.nodes[key].policy.repr == Repr.value);
    static assert(schema.nodes[value].policy.repr == Repr.name);
    static assert(schema.nodes[value].policy.caseStyle
        == CaseStyle.screamingSnakeCase);
}

@("wired.schema.annotationsArePreserved")
@safe pure unittest
{
    @OpenAnnotation("type docs")
    static struct Shape
    {
        @OpenAnnotation("field role") int value;
    }
    enum schema = wireSchemaOf!(Json, Shape);
    enum field = schema.edges[schema.nodes[0].firstEdge];
    static assert(schema.nodes[0].annotationCount == 1);
    static assert(schema.annotations[schema.nodes[0].firstAnnotation].value
        == `OpenAnnotation("type docs")`);
    static assert(schema.nodes[field].annotationCount == 1);
    static assert(schema.annotations[schema.nodes[field].firstAnnotation].typeName
        == "OpenAnnotation");
}

@("wired.schema.digestWireSurfaceOnly")
@safe pure unittest
{
    static struct Stable { int value; }
    static struct SameSurface { int value; }
    static struct Renamed { @WireName!Json("renamed") int value; }
    @OpenAnnotation("documentation only")
    static struct Documented { int value; }

    static assert(wireSchemaDigest!(Json, Stable)
        == wireSchemaDigest!(Json, SameSurface));
    static assert(wireSchemaDigest!(Json, Stable)
        != wireSchemaDigest!(Json, Renamed));
    static assert(wireSchemaDigest!(Json, Stable)
        == wireSchemaDigest!(Json, Documented));
    static assert(wireSchemaDigest!(Json, Stable).length == 16);
    static assert(wireSchemaDigest!(Json, Stable)
        == wireSchemaDigest!(Json, Stable));

    @WireRepr!Json(Repr.value)
    enum ValuesA { one = 1, two = 2 }
    @WireRepr!Json(Repr.value)
    enum ValuesB { one = 1, two = 3 }
    static assert(wireSchemaDigest!(Json, ValuesA)
        != wireSchemaDigest!(Json, ValuesB));
}
