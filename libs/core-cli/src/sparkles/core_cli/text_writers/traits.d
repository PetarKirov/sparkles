/**
@nogc conversion traits for output range text writing.

Provides compile-time introspection templates that detect whether a type
supports various forms of `toString` conversion, with and without @nogc
compatibility.
*/
module sparkles.core_cli.text_writers.traits;

import std.range.primitives : isOutputRange;
import sparkles.core_cli.smallbuffer : SmallBuffer;

// ─────────────────────────────────────────────────────────────────────────────
// Slicing Trait (auto-decoding–free)
// ─────────────────────────────────────────────────────────────────────────────

/// True if `R` supports contiguous data access via `r[i .. j]` or
/// `r.data[i .. j]`, returning the same type or a dynamic array, with
/// `size_t` length — without Phobos auto-decoding restrictions.
///
/// Unlike `std.range.primitives.hasSlicing`, this does not rely on Phobos
/// range introspection and therefore:
///   - Treats `char[]` and `wchar[]` as sliceable (no auto-decoding).
///   - Accepts slices returning either `R` or `T[]`.
///   - Supports `.data`-property access for output-range writers.
enum hasSlicing(R) =
    is(typeof(checkDirectSlicing!R)) ||
    is(typeof(checkDataSlicing!R));

/// Dynamic arrays satisfy `hasSlicing`, including narrow strings
/// that Phobos rejects due to auto-decoding.
@("hasSlicing.dynamicArrays")
@safe pure nothrow @nogc
unittest
{
    static assert(hasSlicing!(int[]));
    static assert(hasSlicing!(double[]));
    static assert(hasSlicing!(dchar[]));

    // These fail Phobos's std.range.primitives.hasSlicing due to auto-decoding
    static assert(hasSlicing!(char[]));
    static assert(hasSlicing!(wchar[]));
    static assert(hasSlicing!(string));
    static assert(hasSlicing!(wstring));
}

/// Output-range writers satisfy `hasSlicing` via the relaxed return type
/// (slice returns `T[]` instead of the writer type itself).
@("hasSlicing.writers")
@safe pure nothrow @nogc
unittest
{
    import std.array : Appender;

    static assert(hasSlicing!(Appender!string));
    static assert(hasSlicing!(Appender!(int[])));
    static assert(hasSlicing!(SmallBuffer!(char, 16)));
    static assert(hasSlicing!(SmallBuffer!(int, 8)));
}

/// Types without slicing or length do not satisfy `hasSlicing`.
@("hasSlicing.negative")
@safe pure nothrow @nogc
unittest
{
    static assert(!hasSlicing!int);
    static assert(!hasSlicing!(int[string]));

    // Output-only types with no slice support
    struct PutOnly
    {
        void put(char c) {}
    }

    static assert(!hasSlicing!PutOnly);
}

// ─────────────────────────────────────────────────────────────────────────────
// Output Range Traits
// ─────────────────────────────────────────────────────────────────────────────

/// True if `Writer` is an output range with contiguous data access via slicing.
enum isContiguousOutputRange(Writer, T) =
    isOutputRange!(Writer, T) && hasSlicing!Writer;

/// `std.array.Appender` satisfies `isContiguousOutputRange`.
@("isContiguousOutputRange.appender")
@safe pure nothrow @nogc
unittest
{
    import std.array : Appender;

    static assert(isContiguousOutputRange!(Appender!string, char));
    static assert(isContiguousOutputRange!(Appender!(int[]), int));
}

/// `SmallBuffer` satisfies `isContiguousOutputRange`.
@("isContiguousOutputRange.smallBuffer")
@safe pure nothrow @nogc
unittest
{
    static assert(isContiguousOutputRange!(SmallBuffer!(char, 16), char));
    static assert(isContiguousOutputRange!(SmallBuffer!(int, 8), int));
}

// ─────────────────────────────────────────────────────────────────────────────
// Implementation Details
// ─────────────────────────────────────────────────────────────────────────────

/// Check function: `r[i .. j]` with `size_t` length, returning `R` or `T[]`.
///
/// Exercises direct slicing: `r.length` and `r[size_t(0) .. size_t(0)]`.
/// If `opDollar` is defined, also checks `r[0 .. $]` and `$ - 1`.
private void checkDirectSlicing(R)(inout int = 0)
{
    R r;
    size_t len = r.length;
    auto s = r[size_t(0) .. size_t(0)];
    alias S = typeof(s);
    static assert(is(S == R) || is(S : E[], E));

    static if (is(typeof(r[0 .. $])))
    {
        static assert(is(typeof(r[0 .. $]) == S));
        static assert(__traits(compiles, r[0 .. $ - 1]));
    }
}

/// Check function: `r.data[i .. j]` with `size_t` length, returning `T[]`.
///
/// Exercises data-property slicing for writers like `Appender` that expose
/// written data via a `.data` property rather than direct `opSlice`.
private void checkDataSlicing(R)(inout int = 0)
{
    R r;
    size_t len = r.length;
    auto s = r.data[size_t(0) .. size_t(0)];
    static assert(is(typeof(s) : E[], E));
}

// ─────────────────────────────────────────────────────────────────────────────
// toString Traits
// ─────────────────────────────────────────────────────────────────────────────

/// True if `T` has a `toString` overload that accepts an output range writer,
/// e.g. `void toString(W)(ref W writer)`.
enum hasOutputRangeToString(T) = __traits(compiles, () {
    T t = T.init;
    SmallBuffer!(char, 128) buf;
    t.toString(buf);
}());

/// True if `T` has a @nogc-compatible `toString` overload that accepts an
/// output range writer.
enum hasNogcOutputRangeToString(T) = __traits(compiles, () @nogc {
    T t = T.init;
    SmallBuffer!(char, 128) buf;
    t.toString(buf);
}());

/// True if `T` has a `toString` that takes a `scope void delegate(const(char)[])` sink.
enum hasSinkToString(T) = __traits(compiles, () {
    T t = T.init;
    static void sink(const(char)[]) {}
    t.toString(&sink);
}());

/// True if `T` has a @nogc `toString` that takes a @nogc sink delegate.
enum hasNogcSinkToString(T) = __traits(compiles, () @nogc {
    T t = T.init;
    static void sink(const(char)[]) @nogc {}
    t.toString(&sink);
}());

/// True if `T` has a `toString()` that returns `string` and is callable from @nogc.
enum hasNogcStringToString(T) = __traits(compiles, () @nogc {
    T t = T.init;
    string s = t.toString();
}());

/// True if `T` supports `cast(string)` and the cast is @nogc.
enum hasNogcStringCast(T) = __traits(compiles, () @nogc {
    T t = T.init;
    string s = cast(string) t;
}());

/// True if `T` has any @nogc-compatible string conversion mechanism.
enum hasNogcToString(T) =
    hasNogcOutputRangeToString!T ||
    hasNogcSinkToString!T ||
    hasNogcStringToString!T ||
    hasNogcStringCast!T;

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
    struct NogcOutputRangeType
    {
        int value;

        void toString(Writer)(ref Writer w) const @nogc
        {
            import std.range.primitives : put;
            put(w, "NogcOR");
        }
    }

    static assert(hasNogcOutputRangeToString!NogcOutputRangeType);
    static assert(hasOutputRangeToString!NogcOutputRangeType);
    static assert(hasNogcToString!NogcOutputRangeType);
}
