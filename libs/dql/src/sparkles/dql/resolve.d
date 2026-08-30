/**
Lifetime-safe resolution of reflected DQL paths.

`resolveDqlPath` walks the subject's type with the same conventions the
schema generator used — transparent `SumType` alternatives, value-like
wrappers, public `@property` getters, static-array indices — and calls
`sink` synchronously with each addressed value. Nothing is retained: the
sink receives the concrete leaf (a slice into the subject's own storage,
when the leaf is text) and must consume it before returning, which keeps
every `@safe` caller honest about lifetimes without a `@trusted` seam.

The `unknown`/`absent`/`value` distinction is the resolution contract:
$(UL
    $(LI `unknown` — the path does not exist in the schema at all; a typo)
    $(LI `absent` — the path exists, but this value cannot answer it: an
        inactive `SumType` alternative, a null pointer, an out-of-range
        index)
    $(LI `value` — the sink was called exactly once)
)
*/
module sparkles.dql.resolve;

import std.sumtype : match;
import std.traits : ReturnType, TemplateArgsOf, Unqual, getUDAs, hasUDA,
    isStaticArray;

import sparkles.dql.convention : consume, consumeIndex, fieldSegmentName,
    includeField, variantAliasesOf, variantNameOf;
import sparkles.dql.schema : DqlResolution, DqlSchema;
import sparkles.reflection.kind : TypeKind, isScalarKind, typeKindOf;
import sparkles.reflection.member : fieldCount, fieldType, isTextSliceLike,
    propertyGetters, valueLikeGetter;

/// The maximum pointer hops before a chain is treated as absent — cyclic
/// pointer structures terminate, never hang.
private enum size_t maxHops = 64;

private auto propertyValue(T, alias getter)(ref const T value)
{
    return __traits(getMember, value, __traits(identifier, getter))();
}

private DqlResolution resolveValue(T, Sink)(ref const T value,
    scope const(char)[] path, scope Sink sink, size_t hops)
{
    alias K = typeKindOf!T;

    static if (isScalarKind(K))
    {
        if (path.length)
            return DqlResolution.unknown;
        sink(value);
        return DqlResolution.value;
    }
    else static if (K == TypeKind.pointer)
    {
        if (hops >= maxHops || value is null)
            return DqlResolution.absent;
        return resolveValue(*value, path, sink, hops + 1);
    }
    else static if (K == TypeKind.sumType)
    {
        if (!path.length)
            return DqlResolution.value;
        alias Alternatives = TemplateArgsOf!T;
        DqlResolution result = DqlResolution.unknown;
        bool matched;
        static foreach (V; Alternatives)
        {{
            if (!matched)
            {
                size_t consumed = consume(path, variantNameOf!V);
                static foreach (aliasName; variantAliasesOf!V)
                    if (!consumed)
                        consumed = consume(path, aliasName);
                if (consumed)
                {
                    matched = true;
                    bool isActive;
                    value.match!(
                        (const ref V active) {
                            isActive = true;
                            result = resolveValue(active,
                                path[consumed .. $], sink, hops);
                        },
                        (_) {},
                    );
                    if (!isActive)
                        result = DqlResolution.absent;
                }
            }
        }}
        return result;
    }
    else static if (K == TypeKind.aggregate)
    {
        static if (!is(valueLikeGetter!T == void))
        {
            if (!path.length)
            {
                sink(propertyValue!(T, valueLikeGetter!T)(value));
                return DqlResolution.value;
            }
        }
        else static if (isTextSliceLike!T)
        {
            if (!path.length)
            {
                sink(value[]);
                return DqlResolution.value;
            }
        }
        else if (!path.length)
        {
            // A composite is always present, but nothing is handed over.
            return DqlResolution.value;
        }

        DqlResolution result = DqlResolution.unknown;
        bool matched;
        static foreach (i; 0 .. fieldCount!T)
        {
        // The schema's inclusion gate, mirrored: hidden storage does not
        // resolve even when the path spells its identifier correctly.
        static if (includeField!(T, i))
        {{
            alias F = fieldType!(T, i);
            static if (typeKindOf!F == TypeKind.sumType)
            {
                // Transparent sum field: the alternatives' segments attach
                // to this aggregate's address space, exactly as the schema
                // generated them.
                if (!matched)
                {
                    const sub = resolveValue(value.tupleof[i], path, sink,
                        hops);
                    if (sub != DqlResolution.unknown)
                    {
                        matched = true;
                        result = sub;
                    }
                }
            }
            else
            {
                if (!matched)
                {
                    size_t consumed = consume(path, fieldSegmentName!(T, i));
                    if (consumed)
                    {
                        matched = true;
                        result = resolveValue(value.tupleof[i],
                            path[consumed .. $], sink, hops);
                    }
                }
            }
        }}
        }
        static if (is(valueLikeGetter!T == void))
        {
            static foreach (getter; propertyGetters!T)
            {{
                if (!matched)
                {
                    const consumed = consume(path,
                        __traits(identifier, getter));
                    if (consumed)
                    {
                        matched = true;
                        alias R = ReturnType!getter;
                        static if (isScalarKind(typeKindOf!R))
                        {
                            if (consumed == path.length)
                            {
                                sink(propertyValue!(T, getter)(value));
                                result = DqlResolution.value;
                            }
                            else
                                result = DqlResolution.unknown;
                        }
                        else
                            result = DqlResolution.unknown;
                    }
                }
            }}
        }
        return matched ? result : DqlResolution.unknown;
    }
    else static if (K == TypeKind.sequence)
    {
        if (!path.length)
        {
            static if (isStaticArray!T)
                return DqlResolution.value;
            else
                return value is null
                    ? DqlResolution.absent : DqlResolution.value;
        }
        size_t index;
        const consumed = consumeIndex(path, index);
        if (!consumed)
            return DqlResolution.unknown;
        if (index >= value.length)
            return DqlResolution.absent;
        return resolveValue(value[index], path[consumed .. $], sink, hops);
    }
    else static if (K == TypeKind.associative)
    {
        if (!path.length)
            return value is null ? DqlResolution.absent : DqlResolution.value;
        return DqlResolution.unknown;
    }
    else
    {
        if (!path.length)
            return DqlResolution.value;
        return DqlResolution.unknown;
    }
}

/**
Resolves `path` against `subject` and invokes `sink` synchronously with the
addressed value. `sink` is a struct or closure callable with every leaf
type; the shell instantiates it per addressed type — no `void*`, no
registry.
*/
DqlResolution resolveDqlPath(Schema, Sink)(ref const Schema.Subject subject,
    scope const(char)[] path, scope Sink sink)
{
    return resolveValue!(Schema.Subject, Sink)(subject, path, sink, 0);
}

private bool categoryIn(T)(ref const T value,
    scope const(char)[] category) @safe pure nothrow @nogc
{
    alias K = typeKindOf!T;
    static if (K == TypeKind.sumType)
    {
        bool result;
        value.match!((auto ref active) {
            alias V = Unqual!(typeof(active));
            result = category == variantNameOf!V;
            static foreach (aliasName; variantAliasesOf!V)
                result |= category == aliasName;
        });
        return result;
    }
    else static if (K == TypeKind.aggregate)
    {
        static foreach (i; 0 .. fieldCount!T)
        {
            static if (typeKindOf!(fieldType!(T, i)) == TypeKind.sumType)
                if (categoryIn(value.tupleof[i], category))
                    return true;
        }
        return false;
    }
    else
        return false;
}

/// Whether `category` names the active `SumType` alternative of `subject`
/// (root or any transparent nested sum).
bool resolveDqlCategory(Schema)(ref const Schema.Subject subject,
    scope const(char)[] category) @safe pure nothrow @nogc
{
    return categoryIn(subject, category);
}

@("dql.resolve: transparent sums distinguish value, absent, and unknown")
@safe unittest
{
    import std.sumtype : SumType;

    struct AEvent
    {
        int value_;
    }

    struct BEvent
    {
        bool enabled;
    }

    alias Event = SumType!(AEvent, BEvent);
    alias Schema = DqlSchema!Event;
    Event event = AEvent(7);

    struct Take
    {
        int* output;
        void opCall(V)(in V) {}
        void opCall(in int v) { *output = v; }
    }

    int found;
    Take take;
    take.output = &found;

    assert(resolveDqlPath!Schema(event, "a.value_", take)
        == DqlResolution.value);
    assert(found == 7);
    assert(resolveDqlPath!Schema(event, "b.enabled", take)
        == DqlResolution.absent);
    assert(resolveDqlPath!Schema(event, "a.wrong", take)
        == DqlResolution.unknown);
    assert(resolveDqlPath!Schema(event, "missing", take)
        == DqlResolution.unknown);
}

@("dql.resolve: hidden storage neither appears in the schema nor resolves")
@safe unittest
{
    import std.sumtype : SumType;
    import sparkles.dql.schema : isDqlPath;

    struct GuardedEvent
    {
        int open;
        private int secret_ = 42;
    }

    struct PadEvent { int p; }

    alias Schema = DqlSchema!(SumType!(GuardedEvent, PadEvent));
    SumType!(GuardedEvent, PadEvent) event = GuardedEvent(7);

    struct Take
    {
        void opCall(V)(in V) @safe pure nothrow @nogc {}
    }

    Take take;
    assert(isDqlPath!Schema("guarded.open"));
    assert(!isDqlPath!Schema("guarded.secret_"));
    assert(resolveDqlPath!Schema(event, "guarded.open", take)
        == DqlResolution.value);
    // The resolver applies the same inclusion gate as the schema: spelling
    // the hidden field's identifier does not reach its storage.
    assert(resolveDqlPath!Schema(event, "guarded.secret_", take)
        == DqlResolution.unknown);
}

@("dql.resolve: value-like wrappers sink their property value")
@safe unittest
{
    struct InlineText
    {
        private char[16] bytes_;
        private ushort length_;

        @property const(char)[] value() const return pure nothrow @nogc
            => bytes_[0 .. length_];
    }

    struct Holder
    {
        InlineText text;
    }

    alias Schema = DqlSchema!Holder;
    InlineText inner;
    inner.bytes_[0 .. 5] = "hello";
    inner.length_ = 5;
    Holder holder;
    holder.text = inner;

    struct Match
    {
        bool* hit;
        void opCall(V)(in V) {}
        void opCall(scope const(char)[] v) { *hit = v == "hello"; }
    }

    bool hit;
    Match sink;
    sink.hit = &hit;

    assert(resolveDqlPath!Schema(holder, "text", sink)
        == DqlResolution.value);
    assert(hit);
}
