/**
The naming and addressing conventions shared by DQL's two walks.

Schema generation (`sparkles.dql.schema`) enumerates a subject type at
compile time; resolution (`sparkles.dql.resolve`) walks a subject value at
run time. Both must answer every naming question identically — what a
`SumType` alternative is called, how a field is spelled, which tokens an
enum member answers to, how a path segment is consumed — or a canonical
path the parser accepts stops resolving. This module is the single source
of those answers; neither walk carries a naming rule of its own.
*/
module sparkles.dql.convention;

import std.traits : getUDAs, hasUDA;

import sparkles.base.text.case_style : CaseStyle, convertCase;
import sparkles.metadata : Aliases, Description, Name;

/// The mechanical query spelling of a variant type name: an `Event` suffix
/// stripped, the rest recased to camelCase (acronym-aware, so `IMEEvent`
/// reads `ime`, not `iME`).
package(sparkles.dql) string mechanicalVariantName(string raw) @safe pure
{
    if (raw.length > 5 && raw[$ - 5 .. $] == "Event")
        raw = raw[0 .. $ - 5];
    return convertCase!(CaseStyle.camelCase)(raw);
}

/// The query segment of a `SumType` alternative: the mechanical spelling of
/// its type name, unless a `@Name` UDA on the variant type overrides it.
package(sparkles.dql) template variantNameOf(V)
{
    static if (hasUDA!(V, Name))
        enum string variantNameOf = getUDAs!(V, Name)[0].name;
    else
        enum string variantNameOf = mechanicalVariantName(V.stringof);
}

/// Additional accepted category tokens for a variant: `@Aliases`.
package(sparkles.dql) template variantAliasesOf(V)
{
    static if (hasUDA!(V, Aliases))
        enum string[] variantAliasesOf = getUDAs!(V, Aliases)[0].names;
    else
        enum string[] variantAliasesOf = [];
}

/// Whether field `i` of `T` is addressable at all: declared `public` (or
/// `export`). Hidden storage neither appears in a schema nor resolves —
/// both walks ask this one template, so the answers cannot drift.
package(sparkles.dql) template includeField(T, size_t i)
{
    import sparkles.reflection.member : isPublic;

    enum bool includeField = isPublic!(T.tupleof[i]);
}

/// The query segment of a declared field: `@Name` on the field, else its
/// declared identifier.
package(sparkles.dql) template fieldSegmentName(T, size_t i)
{
    import sparkles.reflection.member : fieldIdentifier;

    static if (hasUDA!(T.tupleof[i], Name))
        enum string fieldSegmentName = getUDAs!(T.tupleof[i], Name)[0].name;
    else
        enum string fieldSegmentName = fieldIdentifier!(T, i);
}

/// The query segment of a `@property` getter: `@Name` on the getter, else
/// its declared identifier — the one spelling both walks answer to.
package(sparkles.dql) template getterName(alias getter)
{
    static if (hasUDA!(getter, Name))
        enum string getterName = getUDAs!(getter, Name)[0].name;
    else
        enum string getterName = __traits(identifier, getter);
}

/// The getters both walks expose: `T`'s public zero-argument `@property`
/// getters that are readable on a `const` view. A resolver walks
/// `ref const` subjects, so a mutating getter is absent from the schema
/// $(B and) the resolver — a query against it fails closed at parse time
/// instead of failing the eval instantiation.
package(sparkles.dql) template queryGetters(T)
{
    import std.meta : Filter;
    import sparkles.reflection.member : isConstReadable, propertyGetters;

    private enum bool constReadable(alias getter)
        = isConstReadable!(T, getter);
    alias queryGetters = Filter!(constReadable, propertyGetters!T);
}

/// The value-like wrapper rule under the same capability gate: a fieldless
/// single-property value reads as its value only when that property is
/// `const`-readable; otherwise the type is an ordinary opaque aggregate in
/// both walks.
package(sparkles.dql) template queryValueLikeGetter(T)
{
    import sparkles.reflection.member : isConstReadable, valueLikeGetter;

    static if (!is(valueLikeGetter!T == void)
        && isConstReadable!(T, valueLikeGetter!T))
        alias queryValueLikeGetter = valueLikeGetter!T;
    else
        alias queryValueLikeGetter = void;
}

/// Alternative accepted spellings of a field's segment: `@Aliases`.
package(sparkles.dql) template fieldAliasesOf(T, size_t i)
{
    static if (hasUDA!(T.tupleof[i], Aliases))
        enum string[] fieldAliasesOf = getUDAs!(T.tupleof[i], Aliases)[0].names;
    else
        enum string[] fieldAliasesOf = [];
}

/// ditto, for a `@property` getter.
package(sparkles.dql) template getterAliasesOf(alias getter)
{
    static if (hasUDA!(getter, Aliases))
        enum string[] getterAliasesOf = getUDAs!(getter, Aliases)[0].names;
    else
        enum string[] getterAliasesOf = [];
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

/// The `@Description` text of a symbol, or `""`.
package(sparkles.dql) string descriptionOf(alias symbol)() @safe pure
{
    static if (hasUDA!(symbol, Description))
        return getUDAs!(symbol, Description)[0].text;
    else
        return "";
}

/// Matches `segment` at the front of `path`; returns the length consumed
/// (segment plus one separator) or 0 when it does not address this segment.
package(sparkles.dql) size_t consume(scope const(char)[] path,
    scope const(char)[] segment) @safe pure nothrow @nogc
{
    if (path.length < segment.length || path[0 .. segment.length] != segment)
        return 0;
    if (path.length == segment.length)
        return segment.length;
    if (path[segment.length] != '.' && path[segment.length] != '[')
        return 0;
    // A '.' is consumed here; a '[' stays for the index reader.
    return segment.length + (path[segment.length] == '.' ? 1u : 0u);
}

/// Matches a `[digits]` index at the front of `path`; returns the length
/// consumed (including the closing bracket and any separator) or 0. The
/// index arithmetic is overflow-checked.
package(sparkles.dql) size_t consumeIndex(scope const(char)[] path,
    out size_t index) @safe pure nothrow @nogc
{
    if (path.length < 3 || path[0] != '[')
        return 0;
    size_t i = 1;
    bool any;
    while (i < path.length && path[i] >= '0' && path[i] <= '9')
    {
        const digit = cast(size_t)(path[i] - '0');
        if (index > (size_t.max - digit) / 10)
            return 0;
        index = index * 10 + digit;
        any = true;
        i++;
    }
    if (!any || i >= path.length || path[i] != ']')
        return 0;
    i++;
    if (i == path.length)
        return i;
    if (path[i] != '.')
        return 0;
    return i + 1;
}

@("dql.convention: mechanical variant names are acronym-aware")
@safe pure unittest
{
    assert(mechanicalVariantName("PointerEvent") == "pointer");
    assert(mechanicalVariantName("NoWindowEvent") == "noWindow");
    assert(mechanicalVariantName("IMEEvent") == "ime");
    assert(mechanicalVariantName("EndOfInput") == "endOfInput");
    // A type literally named `Event` keeps its name rather than vanishing.
    assert(mechanicalVariantName("Event") == "event");
}

@("dql.convention: consume matches segments and separators")
@safe pure nothrow @nogc
unittest
{
    assert(consume("key.mods", "key") == 4);
    assert(consume("key", "key") == 3);
    assert(consume("keyboard", "key") == 0);
    assert(consume("stops[1]", "stops") == 5); // '[' stays for the index
    size_t index;
    assert(consumeIndex("[12].x", index) == 5 && index == 12);
    assert(consumeIndex("[2]", index) == 3);
    assert(consumeIndex("[]", index) == 0);
}
