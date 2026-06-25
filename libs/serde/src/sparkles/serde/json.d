/**
JSON serialization and deserialization.

Maps D values to and from $(REF JSONValue, std, json) by structural
introspection: scalars, enums (via $(REF enumToString, sparkles,base,text,enums)
and its `@StringRepresentation` policy), arrays, associative arrays (string- or
enum-keyed), `SumType`, `Nullable`, `Ternary`, `SysTime`, and aggregates of
those.

The deserialization surface is `Expected`-based: $(LREF tryFromJSON) returns an
`Expected` carrying either the decoded value or the `Exception` explaining the
failure, and the throwing $(LREF fromJSON) is a thin wrapper that rethrows that
exception. Serialization ($(LREF toJSON)) and the file helpers
($(LREF readJSONFile) / $(LREF writeJSONFile)) throw on error.
*/
module sparkles.serde.json;

import std.algorithm : map;
import std.array : array;
import std.datetime : SysTime;
import std.json : JSONOptions, JSONValue, parseJSON;
import std.string : strip;
import std.sumtype : SumType, isSumType, match;
import std.traits : ForeachType, isArray, isNumeric, isSomeChar;
import std.typecons : Nullable, Ternary;

import expected : Expected, err, ok;

import sparkles.base.text : StringRepresentation, enumToString, readEnumString;

// ─────────────────────────────────────────────────────────────────────────────
// Deserialization
// ─────────────────────────────────────────────────────────────────────────────

/**
Decodes a `JSONValue` into a `T`, never throwing.

The non-throwing foundation of the deserialization API: the recursive decoder
runs inside a `try`/`catch`, so any failure (a type mismatch from `std.json`, an
unknown enum member, an undecodable `SumType`, …) is captured as the `Exception`
error payload rather than propagated.

Params:
    value = the JSON to decode

Returns: An `Expected!(T, Exception)` — the decoded value on success, otherwise
the `Exception` describing the failure.
*/
Expected!(T, Exception) tryFromJSON(T)(const JSONValue value) nothrow
{
    try
        return ok!Exception(value.fromJsonImpl!T);
    catch (Exception e)
        return err!T(e);
}

/**
Decodes a `JSONValue` into a `T`, throwing on failure.

A thin throwing wrapper over $(LREF tryFromJSON): on success it returns the
decoded value, otherwise it rethrows the captured `Exception` (preserving its
message and any chained cause).

Params:
    value = the JSON to decode

Returns: The decoded `T`.

Throws: `Exception` if `value` cannot be decoded into `T`.

See_Also: $(LREF tryFromJSON) for the non-throwing variant.
*/
T fromJSON(T)(const JSONValue value)
{
    auto result = value.tryFromJSON!T;
    if (result.hasValue)
        return result.value;
    throw result.error;
}

///
@system
unittest
{
    struct Point
    {
        int x;
        int y;
    }

    auto json = parseJSON(`{ "x": 1, "y": 2 }`);
    assert(json.fromJSON!Point == Point(1, 2));

    // The non-throwing variant reports failures as an Exception payload.
    auto bad = parseJSON(`{ "x": "oops" }`).tryFromJSON!Point;
    assert(bad.hasError);
}

/// Recursive structural decoder. Throwing mechanism behind $(LREF tryFromJSON);
/// `SumType` variant probing routes through `tryFromJSON` so a variant that does
/// not match is a recoverable miss rather than a thrown error.
private T fromJsonImpl(T)(const JSONValue value)
{
    // Ternary maps JSON null to `unknown`, so it must not take the generic
    // null-to-`T.init` shortcut.
    static if (!is(T == Ternary))
        if (value.isNull)
            return T.init;

    static if (is(T == JSONValue))
        return value;
    else static if (is(T == Ternary))
    {
        if (value.isNull)
            return Ternary.unknown;
        return value.get!bool ? Ternary.yes : Ternary.no;
    }
    else static if (is(T == enum))
        return enumFromJSONString!T(value.get!string);
    else static if (is(T == bool) || is(T == string) || isSomeChar!T || isNumeric!T)
        return value.get!T;
    else static if (isSumType!T)
    {
        static foreach (Variant; T.Types)
        {{
            auto parsed = value.tryFromJSON!Variant;
            if (parsed.hasValue)
                return T(parsed.value);
        }}
        throw new Exception("Failed to deserialize JSON value as " ~ T.stringof);
    }
    else static if (isArray!T)
    {
        alias Element = ForeachType!T;
        return value.array.map!(e => e.fromJsonImpl!Element).array;
    }
    else static if (is(T == SysTime))
        return SysTime.fromISOExtString(
            value.toString(JSONOptions.doNotEscapeSlashes).strip("\""));
    else static if (is(T : Nullable!U, U))
        return T(value.fromJsonImpl!U); // the JSON-null case returned T.init above
    else static if (is(T == struct))
    {
        T result;
        static foreach (idx, field; T.tupleof)
        {{
            enum name = __traits(identifier, field);
            if (auto member = name in value.object)
                if (!member.isNull)
                    result.tupleof[idx] = (*member).fromJsonImpl!(typeof(field));
        }}
        return result;
    }
    else static if (is(T == V[K], V, K))
    {
        V[K] result;
        foreach (key, val; value.object)
        {
            static if (is(K == enum))
                result[enumFromJSONString!K(key)] = val.fromJsonImpl!V;
            else
            {
                static assert(is(K : string),
                    "JSON object keys must be strings or enums, not " ~ K.stringof);
                result[key] = val.fromJsonImpl!V;
            }
        }
        return result;
    }
    else
        static assert(false, "Unsupported type: " ~ T.stringof);
}

/// Decodes a JSON string into the enum member whose `enumToString` name it
/// matches exactly, surfacing the reader's `"expected one of: …"` context on
/// failure.
private T enumFromJSONString(T)(in string value)
if (is(T == enum))
{
    // `readEnumString` is a slice-advancing reader; require it to consume the
    // entire token (an exact match), not just a member-name prefix.
    scope const(char)[] cursor = value;
    auto parsed = readEnumString!T(cursor);
    if (parsed.hasValue && cursor.length == 0)
        return parsed.value;

    const detail = parsed.hasError ? parsed.error.context : null;
    throw new Exception(
        "Cannot deserialize " ~ T.stringof ~ " from JSON string \"" ~ value ~ "\""
        ~ (detail.length ? " (" ~ detail ~ ")" : ""));
}

@("json.fromJSON.associativeArrays")
@system
unittest
{
    struct Node
    {
        string name;
        ulong size;
        Node[string] children;
    }

    auto json = parseJSON(`{
        "name": "root",
        "size": 42,
        "children": {
            "child1": { "name": "child1", "size": 1, "children": {} },
            "child2": {
                "name": "child2",
                "size": 2,
                "children": {
                    "child3": { "name": "child3", "size": 3, "children": {} }
                }
            }
        }
    }`);

    assert(json.fromJSON!Node == Node("root", 42, [
        "child1": Node("child1", 1, null),
        "child2": Node("child2", 2, [
            "child3": Node("child3", 3, null)
        ])
    ]));
}

@("json.fromJSON.sumTypeValuedAA")
@system
unittest
{
    alias Type = SumType!(int, bool[string]);

    auto json = parseJSON(`{ "1": 1, "2": { "a": true } }`);
    assert(json.fromJSON!(Type[string]) == [
        "1": Type(1),
        "2": Type(["a": true])
    ]);

    auto arr = parseJSON(`[1, { "a": true } ]`);
    assert(arr.fromJSON!(Type[]) == [Type(1), Type(["a": true])]);
}

@("json.fromJSON.nestedSumTypes")
@system
unittest
{
    alias InnerType = SumType!(int, bool[string]);
    alias OuterType = SumType!(string, int, InnerType[]);
    alias Type = OuterType[string];

    auto json = parseJSON(`{ "1": "a", "2": 3, "3": [ 1, { "x": true } ] }`);

    Type expected = [
        "1": OuterType("a"),
        "2": OuterType(3),
        "3": OuterType([InnerType(1), InnerType(["x": true])])
    ];
    assert(json.fromJSON!Type == expected);
}

@("json.fromJSON.enumKeyedAA")
@system
unittest
{
    enum Kind
    {
        @StringRepresentation("first-kind") first,
        second
    }

    auto json = parseJSON(`{ "first-kind": 1, "second": 2 }`);
    assert(json.fromJSON!(int[Kind]) == [Kind.first: 1, Kind.second: 2]);
}

@("json.fromJSON.sumTypeScalar")
@system
unittest
{
    alias NumOrString = SumType!(int, string);
    assert(42.JSONValue.fromJSON!NumOrString == NumOrString(42));
    assert("test".JSONValue.fromJSON!NumOrString == NumOrString("test"));
}

@("json.fromJSON.nullable")
@system
unittest
{
    assert(JSONValue(null).fromJSON!(Nullable!int).isNull);

    auto intValue = JSONValue(42).fromJSON!(Nullable!int);
    assert(!intValue.isNull);
    assert(intValue.get == 42);
}

@("json.fromJSON.unknownEnumMemberSurfacesContext")
@system
unittest
{
    enum Kind { first, second }

    auto parsed = parseJSON(`"third"`).tryFromJSON!Kind;
    assert(parsed.hasError);
    // The reader's "expected one of: …" context is surfaced in the message.
    import std.algorithm : canFind;
    assert(parsed.error.msg.canFind("expected one of: first, second"));
}

// ─────────────────────────────────────────────────────────────────────────────
// Serialization
// ─────────────────────────────────────────────────────────────────────────────

/**
Encodes a `T` into a `JSONValue`.

The inverse of $(LREF fromJSON). Enums encode via their `enumToString` name,
`Ternary` as a nullable bool, `SumType` as its active variant, associative
arrays as JSON objects (enum keys via `enumToString`), and aggregates
field-by-field under their member names.

Params:
    value = the value to encode

Returns: The encoded `JSONValue`.
*/
JSONValue toJSON(T)(const T value)
{
    static if (is(T == enum))
        return JSONValue(value.enumToString);
    else static if (is(T == Ternary))
    {
        if (value == Ternary.unknown)
            return JSONValue(null);
        return JSONValue(value == Ternary.yes);
    }
    else static if (is(T == bool) || is(T == string) || isSomeChar!T || isNumeric!T)
        return JSONValue(value);
    else static if (isSumType!T)
        return value.match!(v => v.toJSON);
    else static if (is(T == U[], U))
    {
        static if (isSomeChar!U)
            return JSONValue(value);
        else
            return JSONValue(value.map!(e => e.toJSON).array);
    }
    else static if (is(T == SysTime))
        return JSONValue(value.toISOExtString());
    else static if (is(T : Nullable!U, U))
    {
        if (value.isNull)
            return JSONValue(null);
        return value.get.toJSON!U;
    }
    else static if (is(T == struct))
    {
        JSONValue[string] result;
        static foreach (idx, field; T.tupleof)
            result[__traits(identifier, field)] = value.tupleof[idx].toJSON;
        return JSONValue(result);
    }
    else static if (is(T == V[K], V, K))
    {
        JSONValue[string] result;
        foreach (key, field; value)
        {
            static if (is(K == enum))
                result[key.enumToString] = field.toJSON;
            else
            {
                static assert(is(K : string),
                    "JSON object keys must be strings or enums, not " ~ K.stringof);
                result[key] = field.toJSON;
            }
        }
        return JSONValue(result);
    }
    else
        static assert(false, "Unsupported type: " ~ T.stringof);
}

version (unittest)
{
    private enum TestEnum
    {
        @StringRepresentation("supercalifragilisticexpialidocious")
        a,
        b,
        c
    }

    private struct TestStruct
    {
        int a;
        string b;
        bool c;
    }

    private struct TestStruct2
    {
        int a;
        TestStruct b;
    }
}

@("json.toJSON.scalarsAndAggregates")
@system
unittest
{
    assert(1.toJSON == JSONValue(1));
    assert(true.toJSON == JSONValue(true));
    assert("test".toJSON == JSONValue("test"));

    // Non-immutable char arrays must round-trip in full (regression: the old
    // char-array branch truncated the last character via strlen).
    char[] mutableChars = "test".dup;
    assert(mutableChars.toJSON == JSONValue("test"));

    assert([1, 2, 3].toJSON == JSONValue([1, 2, 3]));
    assert(["a", "b", "c"].toJSON == JSONValue(["a", "b", "c"]));
    assert([TestEnum.a, TestEnum.b, TestEnum.c].toJSON
        == JSONValue(["supercalifragilisticexpialidocious", "b", "c"]));

    TestStruct testStruct = {1, "test", true};
    assert(testStruct.toJSON == JSONValue([
        "a": JSONValue(1), "b": JSONValue("test"), "c": JSONValue(true)
    ]));

    TestStruct2 nested = {1, testStruct};
    assert(nested.toJSON == JSONValue([
        "a": JSONValue(1),
        "b": JSONValue(["a": JSONValue(1), "b": JSONValue("test"), "c": JSONValue(true)])
    ]));
}

@("json.toJSON.nullableAndEnumKeys")
@system
unittest
{
    assert(Nullable!int.init.toJSON == JSONValue(null));
    assert(Nullable!int(42).toJSON == JSONValue(42));

    enum Kind
    {
        @StringRepresentation("first-kind") first,
        second
    }

    // Enum-keyed AAs serialize symmetrically with fromJSON.
    auto json = [Kind.first: 1, Kind.second: 2].toJSON;
    assert(json == JSONValue(["first-kind": JSONValue(1), "second": JSONValue(2)]));
    assert(json.fromJSON!(int[Kind]) == [Kind.first: 1, Kind.second: 2]);
}

@("json.roundTrip.sumTypeAndTernary")
@system
unittest
{
    // SumType encodes via `match` and decodes via variant probing.
    alias NumOrString = SumType!(int, string);
    assert(NumOrString(7).toJSON.fromJSON!NumOrString == NumOrString(7));
    assert(NumOrString("hi").toJSON.fromJSON!NumOrString == NumOrString("hi"));

    // Ternary round-trips through JSON null / true / false.
    assert(Ternary.unknown.toJSON == JSONValue(null));
    foreach (t; [Ternary.yes, Ternary.no, Ternary.unknown])
        assert(t.toJSON.fromJSON!Ternary == t);
}

// ─────────────────────────────────────────────────────────────────────────────
// File helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
Evaluates `value`, rethrowing any failure as an `Exception` chained to
`errorMsg`.

Bridges a throwing expression to a richer diagnostic: on success the value is
returned unchanged; on `Exception` a new `Exception` carrying `errorMsg` is
thrown with the original as its cause.

Params:
    value    = the (lazily evaluated) expression to guard
    errorMsg = context prepended to any failure
    file     = source file of the call site (defaulted)
    line     = source line of the call site (defaulted)

Returns: The evaluated `value`.

Throws: `Exception` wrapping `errorMsg` if evaluating `value` throws.
*/
T tryGet(T)(lazy T value, string errorMsg, string file = __FILE__, size_t line = __LINE__)
{
    try
        return value;
    catch (Exception e)
        throw new Exception(errorMsg, file, line, e);
}

/**
Reads `path`, parses it as JSON, and decodes it into a `T`.

Each stage is guarded by $(LREF tryGet), so a failure to read, parse, or decode
surfaces as a styled, contextual `Exception`.

Params:
    path = filesystem path to the JSON document

Returns: The decoded `T`.

Throws: `Exception` if the file cannot be read, parsed, or decoded into `T`.
*/
T readJSONFile(T)(string path)
{
    import std.file : readText;

    import sparkles.base.styled_template : styledText;

    auto txt = path
        .readText()
        .strip()
        .tryGet(styledText(i"Error reading file: '{bold $(path)}'"));

    auto json = txt
        .parseJSON()
        .tryGet(styledText(i"Error parsing JSON. File contents: '{bold $(txt)}'"));

    return json
        .fromJSON!T()
        .tryGet(styledText(i"Error deserializing {bold $(T.stringof)}. JSON: \n{bold $(json.toPrettyString())}"));
}

/**
Encodes `value` to JSON and writes it to `path`, creating parent directories.

Params:
    value   = the value to serialize
    path    = destination path (its directory is created if missing)
    compact = write a single-line document instead of pretty-printed JSON
*/
void writeJSONFile(T)(const T value, const(char)[] path, bool compact = false)
{
    import std.file : mkdirRecurse, writeFile = write;
    import std.path : dirName;

    auto json = value.toJSON;
    auto text = compact
        ? json.toString(JSONOptions.doNotEscapeSlashes)
        : json.toPrettyString(JSONOptions.doNotEscapeSlashes);
    mkdirRecurse(path.dirName);
    writeFile(path, text);
}
