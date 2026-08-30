/**
Compile-time DQL schema generation over the shared reflection kernel.

`DqlSchema!T` reduces `T` to plain documentation tables — canonical paths
and coarse categories — that the parser validates against and the help
renderer prints. The collection is one direct recursion over the kernel's
member primitives, a `static if` ladder over `typeKindOf` whose cases
mirror `sparkles.dql.resolve.resolveValue` case for case: the path prefix
is an ordinary argument, so a segment can neither leak out of its subtree
nor go missing from one. There is no per-domain policy type: naming is
mechanical (`sparkles.dql.convention`), and the only overrides are the
neutral metadata attributes (`@Name`, `@Aliases`, `@Description`) any
consumer of the metadata package already speaks.

Structural conventions:
$(UL
    $(LI a `SumType` field is $(B transparent) — its alternatives' segments
        attach to the parent path, so an event's `PointerEvent` variant is
        addressed as `pointer.action`, not `payload.pointer.action`)
    $(LI an alternative's segment is its type name minus an `Event` suffix,
        recased to camelCase; `@Name` on the variant type overrides)
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

import sparkles.dql.convention : descriptionOf, enumValueMatches,
    enumValueName, fieldSegmentName, variantAliasesOf, variantNameOf;
import sparkles.dql.help : DqlPathDoc;
import sparkles.metadata : Aliases, Description, Name;
import std.meta : staticIndexOf;
import std.traits : TemplateArgsOf;

import sparkles.reflection.kind : TypeKind, isScalarKind, typeKindOf;
import sparkles.reflection.member : fieldCount, fieldType, isPublic,
    isTextSliceLike, propertyGetters, valueLikeGetter;

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
once per type from one walk of `T` — `paths` and `categories` alias one
table, so the CTFE collection runs a single time per subject.
*/
struct DqlSchema(T)
{
    alias Subject = T;

    private static immutable CollectedSchema table = collectSchema!T();

    /// Every canonically addressable path, in walk order.
    static immutable DqlPathDoc[] paths = table.paths;
    /// One entry per `SumType` alternative reached by the walk.
    static immutable DqlCategoryDoc[] categories = table.categories;
}

// ── the schema walk: direct recursion over the member primitives ─────────────

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

/// The two tables one walk of a subject type produces.
private struct CollectedSchema
{
    DqlPathDoc[] paths;
    DqlCategoryDoc[] categories;
}

private string joinSegment(string prefix, string segment) @safe pure
    => prefix.length ? prefix ~ "." ~ segment : segment;

private void emitLeaf(T)(ref CollectedSchema o, string path,
    string description) @safe pure
{
    o.paths ~= DqlPathDoc(path, T.stringof, description, leafExample!T(path));
}

/// One recursion step. `Seen` holds the aggregate/sum types on the current
/// descent branch — the only kinds that can close a cycle — so a
/// self-referential chain terminates while sibling fields of one type both
/// enumerate.
private void collectType(T, Seen...)(ref CollectedSchema o, string prefix)
{
    static if (staticIndexOf!(T, Seen) < 0)
        collectTypeBody!(T, Seen)(o, prefix);
}

/**
The `static if` ladder from a type's `typeKindOf` to its addresses — the
compile-time mirror of `resolveValue`'s ladder in `sparkles.dql.resolve`.
The prefix is a plain argument: each case passes exactly the prefix its
subtree owns, so a nested transparent sum cannot disturb the segments of
the fields declared after it, and a skipped subtree leaks nothing.
*/
private void collectTypeBody(T, Seen...)(ref CollectedSchema o, string prefix)
{
    enum K = typeKindOf!T;
    static if (K == TypeKind.sumType)
    {
        static foreach (V; TemplateArgsOf!T)
        {{
            o.categories ~= DqlCategoryDoc(variantNameOf!V,
                variantAliasesOf!V, descriptionOf!V);
            collectType!(V, Seen, T)(o, joinSegment(prefix, variantNameOf!V));
        }}
    }
    else static if (K == TypeKind.aggregate)
    {
        static if (!is(valueLikeGetter!T == void))
        {
            // A fieldless single-property value reads as its value.
            emitLeaf!(ReturnType!(valueLikeGetter!T))(o, prefix, "");
        }
        else static if (isTextSliceLike!T)
        {
            // A text buffer reads as the text it slices to.
            emitLeaf!(const(char)[])(o, prefix, "");
        }
        else
        {
            const before = o.paths.length;
            static foreach (i; 0 .. fieldCount!T)
            {{
                // Hidden storage is not addressable; computed values enter
                // through the getter loop below.
                static if (isPublic!(T.tupleof[i]))
                {
                    alias F = fieldType!(T, i);
                    static if (typeKindOf!F == TypeKind.sumType)
                        // Transparent sum: the alternatives' segments attach
                        // to this aggregate's address space.
                        collectType!(F, Seen, T)(o, prefix);
                    else
                        collectType!(F, Seen, T)(o,
                            joinSegment(prefix, fieldSegmentName!(T, i)));
                }
            }}
            static foreach (getter; propertyGetters!T)
            {{
                alias R = ReturnType!getter;
                static if (isScalarKind(typeKindOf!R))
                {
                    static if (hasUDA!(getter, Name))
                        enum string getterSegment
                            = getUDAs!(getter, Name)[0].name;
                    else
                        enum string getterSegment
                            = __traits(identifier, getter);
                    emitLeaf!R(o, joinSegment(prefix, getterSegment),
                        descriptionOf!getter);
                }
            }}
            // An aggregate with no addressable members (an empty variant
            // such as `closeRequested`) is still present at its own address.
            if (o.paths.length == before && prefix.length)
                emitLeaf!T(o, prefix, "");
        }
    }
    else static if (K == TypeKind.sequence)
    {
        static if (isStaticArray!T)
        {
            // Static arrays enumerate their indices.
            static foreach (idx; 0 .. T.length)
                collectType!(typeof(T.init[0]), Seen, T)(o,
                    prefix ~ "[" ~ idx.to!string ~ "]");
        }
        // Dynamic elements have no finite address.
    }
    else static if (K == TypeKind.pointer)
    {
        collectType!(typeof(*T.init), Seen, T)(o, prefix);
    }
    else static if (isScalarKind(K))
    {
        emitLeaf!T(o, prefix, "");
    }
    // opaque / associative: no address.
}

private CollectedSchema collectSchema(T)() @safe
{
    CollectedSchema o;
    collectType!T(o, "");
    return o;
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

@("dql.schema: a nested transparent sum keeps the enclosing prefix")
@safe unittest
{
    import std.sumtype : SumType;

    struct RedEvent { int r; }
    struct BlueEvent { int b; }
    struct PadEvent { int p; }

    // Fields declared AFTER the nested sum field must keep the enclosing
    // variant's prefix — the shape the mark-stack collector got wrong.
    struct HostEvent
    {
        SumType!(RedEvent, BlueEvent) colour;
        int after;
        bool tail;
    }

    alias Schema = DqlSchema!(SumType!(HostEvent, PadEvent));

    assert(isDqlPath!Schema("host.red.r"));
    assert(isDqlPath!Schema("host.blue.b"));
    assert(isDqlPath!Schema("host.after"));
    assert(isDqlPath!Schema("host.tail"));
    assert(isDqlPath!Schema("pad.p"));
    assert(!isDqlPath!Schema("after"));
    assert(!isDqlPath!Schema("tail"));
}

@("dql.schema: a value-like alternative leaks no prefix onto its siblings")
@safe unittest
{
    import std.sumtype : SumType;

    struct Tag
    {
        private int value_ = 1;
        @property int value() const pure nothrow @nogc => value_;
    }

    struct StopEvent { bool forced; }
    struct GoEvent { int speed; }

    // The value-like first alternative is a leaf at its own address; the
    // later alternatives' paths carry no trace of it — the shape where the
    // skipped-subtree walk left its variant segment unpopped.
    alias Schema = DqlSchema!(SumType!(Tag, StopEvent, GoEvent));

    assert(Schema.paths.length == 3);
    assert(isDqlPath!Schema("tag"));
    assert(isDqlPath!Schema("stop.forced"));
    assert(isDqlPath!Schema("go.speed"));
    assert(!isDqlPath!Schema("tag.stop.forced"));
    assert(!isDqlPath!Schema("tag.go.speed"));
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
