/**
Compile-time DQL schema generation over the shared reflection kernel.

`DqlSchema!T` walks `T` with `sparkles.reflection.visit` and reduces the walk
to plain documentation tables — canonical paths and coarse categories — that
the parser validates against and the help renderer prints. There is no
per-domain policy type: naming is mechanical, and the only overrides are the
neutral metadata attributes (`@Name`, `@Aliases`, `@Description`) any
consumer of the metadata package already speaks.

Structural conventions:
$(UL
    $(LI a `SumType` field is $(B transparent) — its alternatives' segments
        attach to the parent path, so an event's `PointerEvent` variant is
        addressed as `pointer.action`, not `payload.pointer.action`)
    $(LI an alternative's segment is its type name minus an `Event` suffix,
        first letter lowered; `@Name` on the variant type overrides)
    $(LI a fieldless value type whose single `@property` is the value
        (`ScaleFactor`), or that slices to UTF-8 text (`InlineBuffer!(char, N)`),
        is a leaf at its own address)
    $(LI public `@property` getters are leaves; declared fields descend)
    $(LI static arrays enumerate their indices; dynamic arrays are present
        but their elements have no finite address)
)
*/
module sparkles.dql.schema;

import std.conv : to;
import std.traits : isStaticArray, ReturnType, getUDAs, hasUDA;

import sparkles.dql.help : DqlPathDoc;
import sparkles.metadata : Aliases, Description, Name;
import sparkles.reflection.kind : TypeKind, isScalarKind, typeKindOf;
import sparkles.reflection.member : fieldIdentifier, fieldType,
    isTextSliceLike, valueLikeGetter;
import sparkles.reflection.visit : VisitControl, visitType;

/// Runtime outcome of resolving one statically known path.
enum DqlResolution : ubyte
{
    unknown, /// no such path exists in the schema
    absent,  /// the path exists but its variant/container is absent
    value,   /// the sink received the concrete value exactly once
}

/// Description of one coarse event category.
struct DqlCategoryDoc
{
    string name;        /// the canonical category token
    string[] aliases;   /// additional accepted tokens
    string description; /// `@Description` on the variant type
}

/**
The reflected DQL schema of `T`: canonical paths and categories, generated
once per type from the reflection kernel's walk of `T`.
*/
struct DqlSchema(T)
{
    alias Subject = T;

    /// Every canonically addressable path, in walk order.
    static immutable DqlPathDoc[] paths = collectSchema!T().paths;
    /// One entry per `SumType` alternative reached by the walk.
    static immutable DqlCategoryDoc[] categories = collectSchema!T().categories;
}

// ── mechanical naming ────────────────────────────────────────────────────────

private string stripEventSuffix(string raw) @safe pure
    => raw.length > 5 && raw[$ - 5 .. $] == "Event" ? raw[0 .. $ - 5] : raw;

private string lowerFirst(string value) @safe pure
{
    if (!value.length || value[0] < 'A' || value[0] > 'Z')
        return value;
    auto result = value.dup;
    result[0] = cast(char)(result[0] + ('a' - 'A'));
    return result;
}

/// The query segment of a `SumType` alternative: the type name minus an
/// `Event` suffix, first letter lowered. A `@Name` UDA on the variant type
/// overrides the mechanical spelling.
package(sparkles.dql) template variantNameOf(V)
{
    static if (hasUDA!(V, Name))
        enum string variantNameOf = getUDAs!(V, Name)[0].name;
    else
        enum string variantNameOf = lowerFirst(stripEventSuffix(V.stringof));
}

/// Additional accepted category tokens for a variant: `@Aliases`.
package(sparkles.dql) template variantAliasesOf(V)
{
    static if (hasUDA!(V, Aliases))
        enum string[] variantAliasesOf = getUDAs!(V, Aliases)[0].names;
    else
        enum string[] variantAliasesOf = [];
}

/// The query segment of a declared field: `@Name` on the field, else its
/// declared identifier.
package(sparkles.dql) template fieldSegmentName(T, size_t i)
{
    static if (hasUDA!(T.tupleof[i], Name))
        enum string fieldSegmentName = getUDAs!(T.tupleof[i], Name)[0].name;
    else
        enum string fieldSegmentName = fieldIdentifier!(T, i);
}

/// The canonical query spelling of an enum member: `@Name`, else the
/// declared identifier.
package(sparkles.dql) template enumValueName(E, string member)
{
    static if (hasUDA!(__traits(getMember, E, member), Name))
        enum string enumValueName
            = getUDAs!(__traits(getMember, E, member), Name)[0].name;
    else
        enum string enumValueName = member;
}

/// `true` when `name` addresses `value` under its declared identifier, its
/// `@Name`, or one of its `@Aliases`.
package(sparkles.dql) bool enumValueMatches(E)(E value, scope const(char)[] name)
    @safe pure nothrow @nogc
if (is(E == enum))
{
    static foreach (member; __traits(allMembers, E))
    {{
        alias M = __traits(getMember, E, member);
        if (value == M)
        {
            if (name == member)
                return true;
            static if (hasUDA!(M, Name))
                if (name == getUDAs!(M, Name)[0].name)
                    return true;
            static if (hasUDA!(M, Aliases))
                static foreach (aliasName; getUDAs!(M, Aliases)[0].names)
                    if (name == aliasName)
                        return true;
            return false;
        }
    }}
    return false;
}

private string descriptionOf(alias symbol)() @safe pure
{
    static if (hasUDA!(symbol, Description))
        return getUDAs!(symbol, Description)[0].text;
    else
        return "";
}

// ── the schema walk: a visitType consumer ────────────────────────────────────

private template firstMemberName(E)
{
    static foreach (i, member; __traits(allMembers, E))
        static if (i == 0)
            enum string firstMemberName = member;
}

private string leafExample(T)(string path) @safe pure
{
    static if (is(T == enum))
        return path ~ " == " ~ firstMemberName!T;
    else static if (typeKindOf!T == TypeKind.boolean)
        return path ~ " == true";
    else static if (typeKindOf!T == TypeKind.text)
        return path ~ " == `text`";
    else
        return path ~ " == 0";
}

/**
Reduces a `visitType` walk of the subject to schema tables. Segments stack
per descent; `SumType` alternatives push a variant segment plus a mark that
`leaveType` pops, which is what makes transparent addressing and category
collection the same walk.
*/
private struct SchemaCollector
{
    string[] segments;
    size_t[] marks;
    size_t[] pathMarks;
    DqlPathDoc[] paths;
    DqlCategoryDoc[] categories;

    private string joined() @safe pure
    {
        string result;
        foreach (segment; segments)
        {
            if (result.length && segment[0] != '[')
                result ~= ".";
            result ~= segment;
        }
        return result;
    }

    private void emitLeaf(T)() @safe pure
    {
        emitLeafWith!T("");
    }

    private void emitLeafWith(T)(string description) @safe pure
    {
        paths ~= DqlPathDoc(joined(), T.stringof, description,
            leafExample!T(joined()));
    }

    VisitControl enterType(T)()
    {
        pathMarks ~= paths.length;

        static if (!is(valueLikeGetter!T == void))
        {
            // A fieldless single-property value reads as its value.
            emitLeafWith!(ReturnType!(valueLikeGetter!T))("");
            return VisitControl.skip;
        }
        else static if (isTextSliceLike!T)
        {
            // A text buffer reads as the text it slices to.
            emitLeafWith!(const(char)[])("");
            return VisitControl.skip;
        }
        else
            return VisitControl.descend;
    }

    void leaf(T)() { emitLeaf!T(); }

    // Hidden storage is not addressable; computed values enter through the
    // property hook below.
    static bool includeField(T, size_t i)() @safe pure nothrow @nogc
    {
        const protection = __traits(getProtection, T.tupleof[i]);
        return protection == "public" || protection == "export";
    }

    void enterField(T, size_t i)()
    {
        static if (typeKindOf!(fieldType!(T, i)) == TypeKind.sumType)
        {
            // Transparent sum: the alternatives' segments attach here.
        }
        else
            segments ~= fieldSegmentName!(T, i);
    }

    void leaveField(T, size_t i)()
    {
        static if (typeKindOf!(fieldType!(T, i)) != TypeKind.sumType)
            segments = segments[0 .. $ - 1];
    }

    void property(alias getter)()
    {
        alias R = ReturnType!getter;
        static if (isScalarKind(typeKindOf!R))
        {
            static if (hasUDA!(getter, Name))
                segments ~= getUDAs!(getter, Name)[0].name;
            else
                segments ~= __traits(identifier, getter);
            emitLeafWith!R(descriptionOf!getter);
            segments = segments[0 .. $ - 1];
        }
    }

    void sumAlternative(V, size_t ai)()
    {
        categories ~= DqlCategoryDoc(variantNameOf!V, variantAliasesOf!V,
            descriptionOf!V);
        segments ~= variantNameOf!V;
        marks ~= segments.length;
    }

    void leaveType(T)()
    {
        // Defensive against an unbalanced leave (should not happen once
        // enterType instantiates for every type).
        if (!pathMarks.length)
            return;
        const pathMark = pathMarks[$ - 1];
        pathMarks = pathMarks[0 .. $ - 1];

        static if (typeKindOf!T == TypeKind.aggregate)
        {
            // An aggregate with no addressable members (an empty variant
            // such as `closeRequested`) is still present at its own address.
            if (paths.length == pathMark && segments.length)
                emitLeafWith!T("");
        }

        // A nested leaveType carries the alternative's segment plus its own
        // field segment (or more); only the alternative's own completion —
        // the stack back at the mark — removes the variant segment.
        if (marks.length && segments.length <= marks[$ - 1])
        {
            segments = segments[0 .. marks[$ - 1] - 1];
            marks = marks[0 .. $ - 1];
        }
    }

    VisitControl sequenceElement(A, E)()
    {
        static if (isStaticArray!A)
        {
            static foreach (idx; 0 .. A.length)
            {{
                segments ~= "[" ~ idx.to!string ~ "]";
                visitType!(E, SchemaCollector)(this);
                segments = segments[0 .. $ - 1];
            }}
        }
        // Static indices were enumerated above; dynamic elements have no
        // finite address. Either way the element type itself is not a leaf.
        return VisitControl.skip;
    }
}

private SchemaCollector collectSchema(T)() @safe
{
    SchemaCollector collector;
    visitType!(T, SchemaCollector)(collector);
    return collector;
}

// ── membership checks (used by the schema-aware parser) ──────────────────────

/// Whether `path` is a canonical path in `Schema`.
bool isDqlPath(Schema)(scope const(char)[] path) @safe pure nothrow @nogc
{
    foreach (ref const item; Schema.paths)
        if (item.path == path)
            return true;
    return false;
}

/// Whether `name` is a canonical category or category alias in `Schema`.
bool isDqlCategory(Schema)(scope const(char)[] name) @safe pure nothrow @nogc
{
    foreach (ref const item; Schema.categories)
    {
        if (item.name == name)
            return true;
        foreach (aliasName; item.aliases)
            if (aliasName == name)
                return true;
    }
    return false;
}

@("dql.schema: transparent SumType addressing")
@safe unittest
{
    import std.sumtype : SumType;

    struct MoveEvent
    {
        int x;
        int y;
    }

    struct StopEvent
    {
        bool forced;
    }

    alias Schema = DqlSchema!(SumType!(MoveEvent, StopEvent));

    assert(Schema.paths.length == 3);
    assert(isDqlPath!Schema("move.x"));
    assert(isDqlPath!Schema("move.y"));
    assert(isDqlPath!Schema("stop.forced"));
    assert(!isDqlPath!Schema("move.z"));
    assert(!isDqlPath!Schema("payload.move.x"));

    assert(isDqlCategory!Schema("move"));
    assert(isDqlCategory!Schema("stop"));
    assert(!isDqlCategory!Schema("payload"));
}

@("dql.schema: nested sums, static arrays, and value-like leaves")
@safe unittest
{
    import std.sumtype : SumType;

    struct InlineText
    {
        private char[16] bytes_;
        private ushort length_;

        @property const(char)[] value() const return pure nothrow @nogc
            => bytes_[0 .. length_];
    }

    struct CommittedEvent
    {
        InlineText text;
    }

    struct CompositionEvent
    {
        int[2] stops;
        InlineText preedit;
    }

    alias Payload = SumType!(CommittedEvent, CompositionEvent);
    struct WindowEvent
    {
        ulong sequence;
        Payload payload;
    }

    alias Schema = DqlSchema!WindowEvent;

    // Envelope fields are top-level; the sum field is transparent.
    assert(isDqlPath!Schema("sequence"));
    assert(isDqlPath!Schema("committed.text"));
    assert(!isDqlPath!Schema("payload.committed.text"));
    // Static arrays enumerate indices; the value-like InlineText is a leaf
    // at its own address, not at ".value".
    assert(isDqlPath!Schema("composition.stops[0]"));
    assert(isDqlPath!Schema("composition.stops[1]"));
    assert(!isDqlPath!Schema("composition.stops[2]"));
    assert(isDqlPath!Schema("composition.preedit"));
    assert(!isDqlPath!Schema("composition.preedit.value"));

    assert(isDqlCategory!Schema("committed"));
    assert(isDqlCategory!Schema("composition"));
}
