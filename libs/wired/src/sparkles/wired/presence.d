/** Presence provenance kept outside the decoded domain value. */
module sparkles.wired.presence;

import std.traits : Unqual;

/** One presence bit per top-level field. Names resolve at compile time;
the ordinary (at most 64 fields) case occupies one machine word. */
struct WireFieldSet(T)
if (is(T == struct))
{
    private enum size_t fields = T.tupleof.length - __traits(isNested, T);
    private size_t[(fields + size_t.sizeof * 8 - 1) / (size_t.sizeof * 8)] words;

    /// Whether the wire supplied the named field, including explicit defaults/nulls.
    bool has(string field)() const @safe pure nothrow @nogc
    {
        enum index = () {
            static foreach (i; 0 .. fields)
                static if (__traits(identifier, T.tupleof[i]) == field)
                    return i;
            return size_t.max;
        }();
        static assert(index != size_t.max, "wired: unknown presence field " ~ T.stringof ~ "." ~ field);
        return hasIndex(index);
    }

    /// Indexed access for format adapters projecting schema fields.
    bool hasIndex(size_t index) const @safe pure nothrow @nogc
    in (index < fields)
        => (words[index / (size_t.sizeof * 8)] & (size_t(1) << (index % (size_t.sizeof * 8)))) != 0;

    /// Records one supplied top-level field.
    package void include(size_t index) @safe pure nothrow @nogc
    in (index < fields)
    {
        words[index / (size_t.sizeof * 8)] |= size_t(1) << (index % (size_t.sizeof * 8));
    }
}

/// Domain value plus wire presence; requesting this wrapper opts into tracking.
struct Decoded(T)
if (is(T == struct))
{
    T value;
    WireFieldSet!T present;
    alias value this;
}

/// The domain payload of a decode request, with provenance wrappers removed.
template WireValue(T)
{
    static if (is(Unqual!T == Decoded!Value, Value))
        alias WireValue = Value;
    else
        alias WireValue = T;
}

/// Presence does not change the value's layout or equality.
@("wired.presence.fieldSet")
@safe pure nothrow @nogc unittest
{
    static struct Settings { int port; string host; }
    static assert(WireFieldSet!Settings.sizeof == size_t.sizeof);
    Decoded!Settings result;
    result.present.include(0);
    assert(result.present.has!"port");
    assert(!result.present.has!"host");
    static assert(is(WireValue!(Decoded!Settings) == Settings));
}

/// Wide aggregates retain every presence bit without shifting beyond a word.
@("wired.presence.moreThanOneWord")
@safe pure nothrow @nogc unittest
{
    static struct Wide
    {
        static foreach (i; 0 .. 70)
            mixin("int field" ~ i.stringof ~ ";");
    }
    WireFieldSet!Wide fields;
    fields.include(69);
    assert(fields.hasIndex(69) && !fields.hasIndex(0));
    static assert(WireFieldSet!Wide.sizeof == 2 * size_t.sizeof);
}
