/**
 * @nogc conversion traits for output range text writing.
 *
 * Provides compile-time introspection templates that detect whether a type
 * supports various forms of `toString` conversion, with and without @nogc
 * compatibility.
 */
module sparkles.core_cli.text_writers.traits;

// ─────────────────────────────────────────────────────────────────────────────
// toString Traits
// ─────────────────────────────────────────────────────────────────────────────

/// True if `T` has a `toString` overload that accepts an output range writer,
/// i.g. `void toString(W)(ref W writer)`.
template hasOutputRangeToString(T)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum hasOutputRangeToString = __traits(compiles, () {
        T t = T.init;
        SmallBuffer!(char, 128) buf;
        t.toString(buf);
    }());
}

/// True if `T` has a @nogc-compatible `toString` overload that accepts an
/// output range writer.
template hasNogcOutputRangeToString(T)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum hasNogcOutputRangeToString = __traits(compiles, () @nogc {
        T t = T.init;
        SmallBuffer!(char, 128) buf;
        t.toString(buf);
    }());
}

/// True if `T` has a `toString` that takes a `scope void delegate(const(char)[])` sink.
template hasSinkToString(T)
{
    enum hasSinkToString = __traits(compiles, () {
        T t = T.init;
        static void sink(const(char)[]) {}
        t.toString(&sink);
    }());
}

/// True if `T` has a @nogc `toString` that takes a @nogc sink delegate.
template hasNogcSinkToString(T)
{
    enum hasNogcSinkToString = __traits(compiles, () @nogc {
        T t = T.init;
        static void sink(const(char)[]) @nogc {}
        t.toString(&sink);
    }());
}

/// True if `T` has a `toString()` that returns `string` and is callable from @nogc.
template hasNogcStringToString(T)
{
    enum hasNogcStringToString = __traits(compiles, () @nogc {
        T t = T.init;
        string s = t.toString();
    }());
}

/// True if `T` supports `cast(string)` and the cast is @nogc.
template hasNogcStringCast(T)
{
    enum hasNogcStringCast = __traits(compiles, () @nogc {
        T t = T.init;
        string s = cast(string) t;
    }());
}

/// True if `T` has any @nogc-compatible string conversion mechanism.
template hasNogcToString(T)
{
    enum hasNogcToString =
        hasNogcOutputRangeToString!T ||
        hasNogcSinkToString!T ||
        hasNogcStringToString!T ||
        hasNogcStringCast!T;
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

// Test struct with @nogc output range toString
private struct NogcOutputRangeType
{
    int value;

    void toString(Writer)(ref Writer w) const @nogc
    {
        import std.range.primitives : put;
        put(w, "NogcOR");
    }
}

@("nogcTraits.builtinTypes")
@safe pure nothrow @nogc
unittest
{
    // Built-in types don't have toString, so traits should be false
    static assert(!hasNogcOutputRangeToString!int);
    static assert(!hasNogcSinkToString!int);
    static assert(!hasNogcStringToString!int);
    static assert(!hasNogcStringCast!int);
    static assert(!hasNogcToString!int);
}

@("nogcTraits.outputRangeToString")
@safe pure nothrow @nogc
unittest
{
    static assert(hasNogcOutputRangeToString!NogcOutputRangeType);
    static assert(hasOutputRangeToString!NogcOutputRangeType);
    static assert(hasNogcToString!NogcOutputRangeType);
}
