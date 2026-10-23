/** Type-shaped adapters lowered to ordinary shared converter boundaries.

Every adapter receives the active format `F` first, so a name-bearing
adapter spells enum members with that format's names (`@WireName!F`). */
module sparkles.wired.adapters;

import std.traits : ForeachType, isDynamicArray, isFloatingPoint, isIntegral,
    isStaticArray, KeyType, Unqual, ValueType;

import expected : Expected, err, ok;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.float_conv : readDecimalFloat, writeShortest;
import sparkles.base.text.readers : readEnumString, readInteger;
import sparkles.base.text.writers : writeEnumMemberName, writeInteger;
import sparkles.wired.policy : AnyFormat;

/// An identity hole inside a structural adapter.
struct Same
{
    static auto toWire(F, T)(T value) => value;
    static Expected!(T, string) fromWire(F, T, W)(W value) => ok!string(cast(T) value);
}

/// Arithmetic/enum values encoded as text through the owned base primitives.
struct Stringly
{
    static string toWire(F, T)(const T value)
    {
        alias V = Unqual!T;
        UniqueBuffer!(char, 64) text;
        static if (is(V == string))
            return value;
        else static if (is(V == bool))
            return value ? "true" : "false";
        else static if (is(V == enum))
            writeEnumMemberName!F(text, value);
        else static if (isIntegral!V)
            writeInteger(text, value);
        else static if (isFloatingPoint!V)
            writeShortest(text, value);
        else
            static assert(false, "wired: Stringly requires an arithmetic value or enum");
        return text[].idup;
    }

    static Expected!(T, string) fromWire(F, T)(scope const(char)[] text)
    {
        static if (is(T == string))
            return ok!string(text.idup);
        else static if (is(T == bool))
        {
            if (text == "true" || text == "false")
                return ok!string(text == "true");
        }
        else
        {
            auto input = text;
            static if (is(T == enum))
                auto parsed = readEnumString!(T, F)(input);
            else static if (isIntegral!T)
                auto parsed = readInteger!T(input);
            else static if (isFloatingPoint!T)
                auto parsed = readDecimalFloat!T(input);
            else
                static assert(false, "wired: Stringly requires an arithmetic value or enum");
            if (parsed.hasValue && input.length == 0)
                return ok!string(parsed.value);
        }
        return err!T("invalid Stringly value");
    }
}

/// Applies an inner adapter to every sequence/static-array element.
struct Elements(Adapter)
{
    alias ElementAdapter = Adapter;

    static auto toWire(F, T)(in T values)
    {
        alias W = typeof(Adapter.toWire!F(ForeachType!T.init));
        static if (isStaticArray!T)
            W[T.length] result;
        else
        {
            W[] result;
            result.length = values.length;
        }
        foreach (i, value; values)
            result[i] = Adapter.toWire!F(value);
        return result;
    }

    static Expected!(T, string) fromWire(F, T, W)(W values)
    {
        alias E = ForeachType!T;
        T result;
        static if (isStaticArray!T)
        {
            if (values.length != T.length)
                return err!T("adapter static-array length mismatch");
        }
        else
            result.length = values.length;
        foreach (i, value; values)
        {
            auto converted = Adapter.fromWire!(F, E)(value);
            if (converted.hasError)
                return err!T(converted.error);
            result[i] = converted.value;
        }
        return ok!string(result);
    }
}

/// Applies independent adapters to map keys and values.
struct Entries(KeyAdapter_, ValueAdapter_)
{
    alias KeyAdapter = KeyAdapter_;
    alias ElementAdapter = ValueAdapter_;

    static auto toWire(F, T)(in T values)
    {
        alias K = typeof(KeyAdapter.toWire!F(KeyType!T.init));
        alias V = typeof(ElementAdapter.toWire!F(ValueType!T.init));
        V[K] result;
        foreach (key, value; values)
            result[KeyAdapter.toWire!F(key)] = ElementAdapter.toWire!F(value);
        return result;
    }

    static Expected!(T, string) fromWire(F, T, W)(W values)
    {
        T result;
        foreach (key, value; values)
        {
            auto convertedKey = KeyAdapter.fromWire!(F, KeyType!T)(key);
            if (convertedKey.hasError)
                return err!T(convertedKey.error);
            auto convertedValue = ElementAdapter.fromWire!(F, ValueType!T)(value);
            if (convertedValue.hasError)
                return err!T(convertedValue.error);
            if (convertedKey.value in result)
                return err!T("adapter produced a duplicate map key");
            result[convertedKey.value] = convertedValue.value;
        }
        return ok!string(result);
    }
}

/// The scalar adapter rejects trailing input and preserves integer boundaries.
@("wired.adapters.stringly")
@safe pure unittest
{
    assert(Stringly.toWire!AnyFormat(ushort.max) == "65535");
    assert(Stringly.fromWire!(AnyFormat, ushort)("65535").value == ushort.max);
    assert(Stringly.fromWire!(AnyFormat, ushort)("65536").hasError);
    assert(Stringly.fromWire!(AnyFormat, ushort)("12junk").hasError);
}

/// Enum text follows the active format's member names in both directions.
@("wired.adapters.stringly.formatNames")
@safe pure unittest
{
    import sparkles.wired.policy : WireName;

    static struct Toml {}
    enum Color { @WireName!Toml("rouge") red, blue }
    assert(Stringly.toWire!Toml(Color.red) == "rouge");
    assert(Stringly.toWire!AnyFormat(Color.red) == "red");
    assert(Stringly.fromWire!(Toml, Color)("rouge").value == Color.red);
    assert(Stringly.fromWire!(Toml, Color)("red").hasError);
}

/// Structural composition preserves sequence lengths and map identities.
@("wired.adapters.structural")
@system unittest
{
    const words = Elements!Stringly.toWire!AnyFormat([ushort(1), ushort(2)]);
    const values = Elements!Stringly.fromWire!(AnyFormat, ushort[2])(words);
    assert(values.hasValue && values.value == [ushort(1), ushort(2)]);
    const mapped = Entries!(Same, Stringly).toWire!AnyFormat(["a": 7u]);
    const back = Entries!(Same, Stringly).fromWire!(AnyFormat, uint[string])(mapped);
    assert(back.hasValue && back.value["a"] == 7);
}
