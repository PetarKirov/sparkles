/**
JSON backend for `sparkles:wired`.

Defines the `Json` format marker and the `Expected`-based encode/decode surface
(`toJSON` / `fromJSON`), driving enum, aggregate, and container handling through
the `sparkles.wired.policy` resolvers under the `Json` tag. Encoding and decoding
never throw — a failure is captured as the `Exception` payload of the returned
`Expected` (`docs/specs/wired/SPEC.md` §4, §9).

This is the incremental backend: scalars and enums are wired up first; the
remaining supported types (§4.2) land alongside the type walk.
*/
module sparkles.wired.json;

import std.json : JSONValue, JSONType, parseJSON;
import std.traits : isFloatingPoint, isIntegral, isSomeChar, OriginalType, Unqual;

import expected : Expected, ok, err;

import sparkles.wired.policy;
import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.enums : enumFromValue;

/// The JSON format marker. `@Wire*` UDAs tagged `!Json` apply under this format;
/// untagged (`AnyFormat`) UDAs apply too (§3).
struct Json
{
}

/// Alias for the encode/decode result: a value or an `Exception` describing the
/// failure — the backend never throws (§9).
alias JsonResult(T) = Expected!(T, Exception);

private JsonResult!T fail(T)(string msg) => err!T(new Exception(msg));

// ─────────────────────────────────────────────────────────────────────────────
// Encoding
// ─────────────────────────────────────────────────────────────────────────────

/// Encodes `value` into a `JSONValue` under the `Json` format, without throwing.
JsonResult!JSONValue toJSON(T)(const T value)
{
    alias U = Unqual!T;

    static if (is(U == bool) || is(U == string))
        return ok!Exception(JSONValue(value));

    else static if (is(U == enum))
        return encodeEnum(value);

    else static if (isIntegral!U)
        return ok!Exception(JSONValue(value));

    else static if (isFloatingPoint!U)
    {
        import std.math : isFinite;

        if (!isFinite(value))
            return fail!JSONValue(
                "Cannot encode " ~ T.stringof ~ " at $: NaN and infinity are not representable in JSON");
        return ok!Exception(JSONValue(value));
    }

    else
        static assert(false, "wired: unsupported type for toJSON: " ~ T.stringof);
}

private JsonResult!JSONValue encodeEnum(E)(const E value)
if (is(E == enum))
{
    enum repr = resolveRepr!(Json, E);

    static if (repr == Repr.value)
        return toJSON(cast(OriginalType!E) value);
    else
    {
        enum style = resolveCaseStyle!(Json, E);
        static foreach (m; __traits(allMembers, E))
            if (value == __traits(getMember, E, m))
                return ok!Exception(JSONValue(wireName!(Json, __traits(getMember, E, m), style)));

        return fail!JSONValue(
            "Cannot encode " ~ E.stringof ~ " at $: value is not a declared member");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

/// Decodes a `JSONValue` into a `T` under the `Json` format, without throwing.
JsonResult!T fromJSON(T)(JSONValue json)
{
    alias U = Unqual!T;

    static if (is(U == bool))
    {
        if (json.type != JSONType.true_ && json.type != JSONType.false_)
            return fail!T("Cannot decode bool at $: expected a JSON boolean");
        return ok!Exception(json.boolean);
    }

    else static if (is(U == string))
    {
        if (json.type != JSONType.string)
            return fail!T("Cannot decode string at $: expected a JSON string");
        return ok!Exception(json.str);
    }

    else static if (is(U == enum))
        return decodeEnum!T(json);

    else static if (isIntegral!U)
        return decodeIntegral!T(json);

    else static if (isFloatingPoint!U)
    {
        switch (json.type)
        {
            case JSONType.float_:    return ok!Exception(cast(T) json.floating);
            case JSONType.integer:   return ok!Exception(cast(T) json.integer);
            case JSONType.uinteger:  return ok!Exception(cast(T) json.uinteger);
            default:
                return fail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON number");
        }
    }

    else
        static assert(false, "wired: unsupported type for fromJSON: " ~ T.stringof);
}

private JsonResult!T decodeIntegral(T)(JSONValue json)
{
    static if (__traits(isUnsigned, T))
    {
        if (json.type == JSONType.uinteger)
        {
            if (json.uinteger > T.max)
                return fail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return ok!Exception(cast(T) json.uinteger);
        }
        if (json.type == JSONType.integer)
        {
            if (json.integer < 0 || json.integer > T.max)
                return fail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return ok!Exception(cast(T) json.integer);
        }
    }
    else
    {
        if (json.type == JSONType.integer)
        {
            if (json.integer < T.min || json.integer > T.max)
                return fail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return ok!Exception(cast(T) json.integer);
        }
        if (json.type == JSONType.uinteger)
        {
            if (json.uinteger > T.max)
                return fail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return ok!Exception(cast(T) json.uinteger);
        }
    }
    return fail!T("Cannot decode " ~ T.stringof ~ " at $: expected an integer");
}

private JsonResult!E decodeEnum(E)(JSONValue json)
if (is(E == enum))
{
    enum repr = resolveRepr!(Json, E);

    static if (repr == Repr.value)
    {
        auto orig = fromJSON!(OriginalType!E)(json);
        if (orig.hasError)
            return err!E(orig.error);
        auto member = enumFromValue!E(orig.value);
        if (member.hasError)
            return fail!E("Cannot decode " ~ E.stringof ~ " at $: " ~ member.error.context);
        return ok!Exception(member.value);
    }
    else
    {
        enum style = resolveCaseStyle!(Json, E);
        if (json.type != JSONType.string)
            return fail!E("Cannot decode " ~ E.stringof ~ " at $: expected a JSON string");

        static foreach (m; __traits(allMembers, E))
            if (json.str == wireName!(Json, __traits(getMember, E, m), style))
                return ok!Exception(__traits(getMember, E, m));

        return fail!E(
            "Cannot decode " ~ E.stringof ~ " at $ from JSON string \"" ~ json.str
            ~ "\": expected one of: " ~ nameList!E);
    }
}

/// The comma-joined resolved member names of `E` under `Json`, for the
/// `"expected one of: …"` decode-error context.
private template nameList(E)
if (is(E == enum))
{
    enum string nameList = () {
        enum style = resolveCaseStyle!(Json, E);
        string s;
        static foreach (i, m; __traits(allMembers, E))
        {
            static if (i)
                s ~= ", ";
            s ~= wireName!(Json, __traits(getMember, E, m), style);
        }
        return s;
    }();
}

@("wired.json.scalars")
@safe unittest
{
    assert(toJSON(true).value == JSONValue(true));
    assert(toJSON("hi").value == JSONValue("hi"));
    assert(toJSON(42).value == JSONValue(42));
    assert(toJSON(3.5).value == JSONValue(3.5));

    assert(fromJSON!bool(JSONValue(true)).value == true);
    assert(fromJSON!string(JSONValue("hi")).value == "hi");
    assert(fromJSON!int(JSONValue(42)).value == 42);
    assert(fromJSON!double(JSONValue(3.5)).value == 3.5);

    // strict kind checking and range checking
    assert(fromJSON!int(JSONValue("42")).hasError);
    assert(fromJSON!ubyte(JSONValue(300)).hasError);
    assert(fromJSON!bool(JSONValue(1)).hasError);
}

@("wired.json.floatRejectsNaN")
@safe unittest
{
    assert(toJSON(double.nan).hasError);
    assert(toJSON(double.infinity).hasError);
}

@("wired.json.enumByName")
@safe unittest
{
    @WireCase!Json(CaseStyle.snakeCase)
    enum Mode
    {
        fastPath,
        @WireName!Json("turbo") slowPath,
    }

    // Encode: recased member name, WireName override wins.
    assert(toJSON(Mode.fastPath).value == JSONValue("fast_path"));
    assert(toJSON(Mode.slowPath).value == JSONValue("turbo"));

    // Decode: round-trips; unknown token surfaces the candidate names.
    assert(fromJSON!Mode(JSONValue("fast_path")).value == Mode.fastPath);
    assert(fromJSON!Mode(JSONValue("turbo")).value == Mode.slowPath);

    auto bad = fromJSON!Mode(JSONValue("nope"));
    assert(bad.hasError);
    assert(bad.error.msg.length > 0);
}

@("wired.json.enumByValue")
@safe unittest
{
    @WireRepr!Json(Repr.value)
    enum Priority { low = 1, high = 5 }

    assert(toJSON(Priority.high).value == JSONValue(5));
    assert(fromJSON!Priority(JSONValue(5)).value == Priority.high);
    assert(fromJSON!Priority(JSONValue(2)).hasError); // not a declared value
}
