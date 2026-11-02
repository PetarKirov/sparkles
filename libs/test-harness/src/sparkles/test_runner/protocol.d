/**
 * The runner protocol's vocabulary, shared by both of its ends: the version
 * range, the framing, and the JSON encoding of the values frames carry
 * (process-model §4). The worker side is $(MREF sparkles,test_runner,worker);
 * the runner links this module from its own pinned revision, so the two ends
 * agree only on what the handshake negotiates, never on a struct layout.
 */
module sparkles.test_runner.protocol;

import std.json : JSONType, JSONValue;

/// The protocol versions this side speaks.
enum uint protocolMin = 1;
/// ditto
enum uint protocolMax = 1;

/// The first byte of every frame (ASCII record separator).
enum char frameMark = '\x1e';

/// The argument that starts a binary as a worker, followed by `<min>-<max>`.
enum string protocolFlag = "--sparkles-test-protocol=";

/// The word a worker's output sentinel starts with, after `frameMark`.
enum string sentinelWord = "sparkles-test-end";

/// The exit status of a worker that shares no version with its runner.
enum int incompatibleStatus = 3;

/// A version range, `[min, max]`.
struct VersionRange
{
    uint min;
    uint max;
}

/// Parses `<min>-<max>`; `false` on anything else.
bool parseVersionRange(string text, out VersionRange range) @safe pure nothrow
{
    import std.algorithm.searching : findSplit;
    import std.conv : ConvException, to;

    auto parts = text.findSplit("-");
    if (!parts[1].length)
        return false;
    try
    {
        range = VersionRange(parts[0].to!uint, parts[2].to!uint);
        return range.min <= range.max;
    }
    catch (Exception)
        return false;
}

/// The highest version both `a` and `b` contain, or `0` when none.
uint selectVersion(VersionRange a, VersionRange b) @safe pure nothrow @nogc
{
    const hi = a.max < b.max ? a.max : b.max;
    const lo = a.min > b.min ? a.min : b.min;
    return lo <= hi ? hi : 0;
}

@("protocol.selectVersion")
@safe pure nothrow
unittest
{
    VersionRange r;
    assert(parseVersionRange("1-3", r) && r == VersionRange(1, 3));
    assert(!parseVersionRange("3-1", r));
    assert(!parseVersionRange("x-1", r));
    assert(!parseVersionRange("7", r));
    assert(selectVersion(VersionRange(1, 3), VersionRange(2, 5)) == 3);
    assert(selectVersion(VersionRange(1, 1), VersionRange(1, 1)) == 1);
    assert(selectVersion(VersionRange(1, 1), VersionRange(99, 99)) == 0);
}

/// The text of one frame: the mark, the object, a line feed.
string frameText(JSONValue frame) @safe
{
    return frameMark ~ frame.toString ~ "\n";
}

/// One frame of type `type` with `members`.
JSONValue frameOf(string type, JSONValue[string] members = null) @safe
{
    members["t"] = JSONValue(type);
    return JSONValue(members);
}

/**
Splits one line of a frames channel into the stray bytes before a frame and
the frame (TRP8). Returns `false` when the line holds no frame, with the whole
line as `stray`. Throws when the bytes after the mark are not a JSON object
with a string `"t"` (TRP9).
*/
bool splitFrame(string line, out string stray, out JSONValue frame) @safe
{
    import std.json : parseJSON;
    import std.string : indexOf;

    const at = line.indexOf(frameMark);
    if (at < 0)
    {
        stray = line;
        return false;
    }
    stray = line[0 .. at];
    frame = parseJSON(line[at + 1 .. $]);
    if (frame.type != JSONType.object || "t" !in frame
        || frame["t"].type != JSONType.string)
        throw new Exception("a frame without a string \"t\": " ~ line[at + 1 .. $]);
    return true;
}

@("protocol.splitFrame")
@safe
unittest
{
    string stray;
    JSONValue frame;
    assert(!splitFrame("hello world", stray, frame) && stray == "hello world");
    assert(splitFrame("x\x1e{\"t\":\"hello\"}", stray, frame));
    assert(stray == "x" && frame["t"].str == "hello");

    import std.exception : assertThrown;

    assertThrown(splitFrame("\x1e[1]", stray, frame));
    assertThrown(splitFrame("\x1e{\"u\":1}", stray, frame));
}

/// The sentinel line a worker writes on its output channel after test `id`.
string sentinelText(size_t id, string token) @safe pure nothrow
{
    import std.conv : to;

    return frameMark ~ sentinelWord ~ " " ~ id.to!string ~ " " ~ token ~ "\n";
}

// ─────────────────────────────────────────────────────────────────────────────
// Values as JSON
// ─────────────────────────────────────────────────────────────────────────────

/++
Encodes `value` as JSON. Structs become objects keyed by field name,
skipping function, delegate, pointer and class fields; enums their integer;
`Nullable` its value or `null`; `Duration` its nanoseconds; a non-finite
floating-point number the string `"nan"`, `"inf"` or `"-inf"`; associative
arrays objects. The decoder ignores members it does not know and leaves
missing ones at their initial value, which is what lets two revisions of
the harness exchange a struct whose fields differ (TRP9).
+/
JSONValue toJson(T)(auto ref const T value)
{
    import core.time : Duration;
    import std.math.traits : isInfinity, isNaN;
    import std.traits : isAssociativeArray, isDynamicArray, isFloatingPoint,
        isIntegral, isSomeString, OriginalType;
    import std.typecons : Nullable;

    static if (is(T == enum))
        return JSONValue(cast(OriginalType!T) value);
    else static if (is(T == bool))
        return JSONValue(value);
    else static if (isSomeString!T)
        return JSONValue(value.idup);
    else static if (is(T : const(char)) || is(T : const(dchar)))
        return JSONValue(cast(uint) value);
    else static if (isIntegral!T)
        return JSONValue(value);
    else static if (isFloatingPoint!T)
    {
        if (value.isNaN)
            return JSONValue("nan");
        if (value.isInfinity)
            return JSONValue(value > 0 ? "inf" : "-inf");
        return JSONValue(cast(double) value);
    }
    else static if (is(T == Duration))
        return JSONValue(value.total!"nsecs");
    else static if (is(T == Nullable!U, U))
        return value.isNull ? JSONValue(null) : toJson(value.get);
    else static if (isAssociativeArray!T)
    {
        JSONValue[string] members;
        foreach (k, ref v; value)
            members[k.idup] = toJson(v);
        return JSONValue(members);
    }
    else static if (isDynamicArray!T)
    {
        JSONValue[] items;
        foreach (ref e; value)
            items ~= toJson(e);
        return JSONValue(items);
    }
    else static if (is(T == struct))
    {
        JSONValue[string] members;
        static foreach (i, F; typeof(T.tupleof))
            static if (isEncodedField!F)
                members[__traits(identifier, T.tupleof[i])] = toJson(value.tupleof[i]);
        return JSONValue(members);
    }
    else
        static assert(false, "toJson: unsupported " ~ T.stringof);
}

/// Decodes what $(LREF toJson) encoded.
T fromJson(T)(const JSONValue json)
{
    import core.time : Duration, nsecs;
    import std.traits : isAssociativeArray, isDynamicArray, isFloatingPoint,
        isIntegral, isSomeString, KeyType, OriginalType, Unqual, ValueType;
    import std.typecons : Nullable;

    alias M = Unqual!T;
    static if (is(M == enum))
        return cast(T) fromJson!(OriginalType!M)(json);
    else static if (is(M == bool))
        return json.type == JSONType.true_;
    else static if (isSomeString!M)
        return json.type == JSONType.string ? cast(T) json.str : T.init;
    else static if (is(M == char) || is(M == wchar) || is(M == dchar))
        return cast(T) fromJson!uint(json);
    else static if (isIntegral!M)
    {
        switch (json.type)
        {
            case JSONType.integer:  return cast(T) json.integer;
            case JSONType.uinteger: return cast(T) json.uinteger;
            case JSONType.float_:   return cast(T) json.floating;
            default:                return T.init;
        }
    }
    else static if (isFloatingPoint!M)
    {
        switch (json.type)
        {
            case JSONType.integer:  return cast(T) json.integer;
            case JSONType.uinteger: return cast(T) json.uinteger;
            case JSONType.float_:   return cast(T) json.floating;
            case JSONType.string:
                return json.str == "inf" ? T.infinity
                    : json.str == "-inf" ? -T.infinity : T.nan;
            default:                return T.nan;
        }
    }
    else static if (is(M == Duration))
        return fromJson!long(json).nsecs;
    else static if (is(M == Nullable!U, U))
        return json.type == JSONType.null_ ? T.init : T(fromJson!U(json));
    else static if (isAssociativeArray!M)
    {
        Unqual!(ValueType!M)[Unqual!(KeyType!M)] result;
        if (json.type == JSONType.object)
            foreach (k, ref v; json.object)
                result[k] = fromJson!(Unqual!(ValueType!M))(v);
        return cast(T) result;
    }
    else static if (isDynamicArray!M)
    {
        alias E = typeof(M.init[0]);
        Unqual!E[] result;
        if (json.type == JSONType.array)
            foreach (ref v; json.array)
                result ~= fromJson!(Unqual!E)(v);
        return (() @trusted => cast(T) result)();
    }
    else static if (is(M == struct))
    {
        M result;
        if (json.type == JSONType.object)
            static foreach (i, F; typeof(M.tupleof))
                static if (isEncodedField!F)
                    if (auto member = __traits(identifier, M.tupleof[i]) in json.object)
                    {
                        static if (is(F == Unqual!F))
                            result.tupleof[i] = fromJson!F(*member);
                        else
                        {
                            // A `const` field of a value this function owns.
                            auto field = (() @trusted => cast(Unqual!F*) &result.tupleof[i])();
                            *field = fromJson!(Unqual!F)(*member);
                        }
                    }
        return result;
    }
    else
        static assert(false, "fromJson: unsupported " ~ T.stringof);
}

/// Whether a field of type `F` crosses the protocol.
private enum bool isEncodedField(F) = !is(F == function) && !is(F == delegate)
    && !is(F : const(void)*) && !is(F == class) && !is(F == interface)
    && !__traits(isStaticArray, F) && !is(typeof(*F.init) == function);

@("protocol.json.roundTrip")
@system
unittest
{
    import core.time : Duration, msecs;
    import std.math.traits : isNaN;
    import std.typecons : Nullable;

    enum Color { red = 1, blue = 4 }
    static struct Inner { string name; double ratio = double.nan; }
    static struct Outer
    {
        int i = -3;
        ulong big = ulong.max;
        Color color = Color.blue;
        uint flags = 5;
        string[string] labels;
        immutable(string)[] info;
        const(Inner)[] inners;
        Nullable!Inner maybe;
        Nullable!Inner absent;
        Duration took;
        void function() fn;
        double inf = double.infinity;
    }

    Outer o;
    o.labels = ["dataset": "twitter"];
    o.info = ["a", "b"];
    o.inners = [Inner("x", 0.5), Inner("y")];
    o.maybe = Inner("m", 1);
    o.took = 1500.msecs;
    o.fn = () {};

    const back = fromJson!Outer(toJson(o));
    assert(back.i == -3 && back.big == ulong.max && back.color == Color.blue);
    assert(back.labels.length == 1 && back.labels["dataset"] == "twitter");
    assert(back.info == ["a", "b"]);
    assert(back.inners.length == 2 && back.inners[0] == Inner("x", 0.5));
    assert(back.inners[1].ratio.isNaN);
    assert(!back.maybe.isNull && back.maybe.get.name == "m" && back.absent.isNull);
    assert(back.took == 1500.msecs && back.fn is null && back.inf == double.infinity);

    // Unknown members are ignored and missing ones keep their initial value.
    import std.json : parseJSON;

    const partial = fromJson!Outer(parseJSON(`{"i": 7, "unknown": [1, 2]}`));
    assert(partial.i == 7 && partial.big == ulong.max && partial.color == Color.blue);
}
