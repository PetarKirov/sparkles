/**
JSON backend for `sparkles:wired`.

Defines the `Json` format marker and the `Expected`-based encode/decode surface
(`toJSON` / `fromJSON`), driving enum, aggregate, and container handling through
the `sparkles.wired.policy` resolvers under the `Json` tag. Encoding and decoding
never throw — a failure is captured as the `Exception` payload of the returned
`Expected` (`docs/specs/wired/SPEC.md` §4, §9).

This is the incremental backend: scalars, enums, arrays, and aggregates are wired
up; the remaining supported types (`SumType`, null-aware wrappers, `SysTime`,
`@WireConvert`, associative arrays) land alongside the type walk.
*/
module sparkles.wired.json;

import std.datetime.systime : SysTime;
import std.json : JSONValue, JSONType;
import std.sumtype : isSumType, match, SumType;
import std.traits : isFloatingPoint, isIntegral, isSomeChar, OriginalType,
    TemplateArgsOf, Unqual;
import std.typecons : Nullable, Ternary;

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

    static if (hasConvert!(Json, U))
        return encodeVia!(convertOf!(Json, U), U)(value);

    else static if (is(U == bool) || is(U == string))
        return ok!Exception(JSONValue(value));

    else static if (is(U == enum))
        return encodeEnumWith!(U, resolveRepr!(Json, U), resolveCaseStyle!(Json, U))(value);

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

    else static if (is(U == E[], E))
    {
        static if (isSomeChar!E)
            return ok!Exception(JSONValue(value.idup));
        else
        {
            JSONValue[] arr;
            foreach (e; value)
            {
                auto r = toJSON(e);
                if (r.hasError)
                    return err!JSONValue(r.error);
                arr ~= r.value;
            }
            return ok!Exception(JSONValue(arr));
        }
    }

    else static if (is(U == V[K], V, K))
        return encodeAA(value);

    else static if (is(U == Nullable!N, N))
    {
        if (value.isNull)
            return ok!Exception(JSONValue(null));
        return toJSON(value.get);
    }

    else static if (is(U == Ternary))
    {
        if (value == Ternary.unknown)
            return ok!Exception(JSONValue(null));
        return ok!Exception(JSONValue(value == Ternary.yes));
    }

    else static if (is(U == SysTime))
        return ok!Exception(JSONValue(value.toUTC.toISOExtString));

    else static if (isSumType!U)
        return value.match!(v => toJSON(v));

    else static if (is(U == struct))
        return encodeStruct(value);

    else
        static assert(false, "wired: unsupported type for toJSON: " ~ T.stringof);
}

private JsonResult!JSONValue encodeEnumWith(E, Repr repr, CaseStyle style)(const E value)
if (is(E == enum))
{
    static if (repr == Repr.value)
        return toJSON(cast(OriginalType!E) value);
    else
    {
        static foreach (m; __traits(allMembers, E))
            if (value == __traits(getMember, E, m))
                return ok!Exception(JSONValue(wireName!(Json, __traits(getMember, E, m), style)));

        return fail!JSONValue(
            "Cannot encode " ~ E.stringof ~ " at $: value is not a declared member");
    }
}

private JsonResult!JSONValue encodeStruct(T)(const T value)
if (is(T == struct))
{
    enum _uniq = checkUniqueFieldKeys!(Json, T);
    enum aggStyle = resolveCaseStyle!(Json, T);

    JSONValue[string] obj;
    static foreach (i; 0 .. T.tupleof.length)
    {{
        enum key = wireName!(Json, T.tupleof[i], aggStyle);
        auto r = encodeFieldValue!(T, i)(value.tupleof[i]);
        if (r.hasError)
            return err!JSONValue(r.error);
        obj[key] = r.value;
    }}
    return ok!Exception(JSONValue(obj));
}

/// Encodes an aggregate field's value, applying the field's value-slot enum
/// policy at the field and one wrapper level; everything else recurses through
/// the type-level `toJSON`. Takes the aggregate type and field index so the
/// field alias carries no instance context.
private JsonResult!JSONValue encodeFieldValue(T, size_t i)(const typeof(T.tupleof[i]) value)
{
    alias V = typeof(T.tupleof[i]);

    static if (hasConvert!(Json, T.tupleof[i]))
        return encodeVia!(convertOf!(Json, T.tupleof[i]), V)(value);

    else static if (is(V == enum))
        return encodeEnumWith!(V,
            resolveReprFor!(Json, WireTarget.all, T.tupleof[i], V),
            resolveCaseFor!(Json, WireTarget.all, T.tupleof[i], V))(value);

    else static if (is(V == E[], E) && is(E == enum))
    {
        JSONValue[] arr;
        foreach (e; value)
        {
            auto r = encodeEnumWith!(E,
                resolveReprFor!(Json, WireTarget.value, T.tupleof[i], E),
                resolveCaseFor!(Json, WireTarget.value, T.tupleof[i], E))(e);
            if (r.hasError)
                return err!JSONValue(r.error);
            arr ~= r.value;
        }
        return ok!Exception(JSONValue(arr));
    }

    else
        return toJSON(value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

/// Decodes a `JSONValue` into a `T` under the `Json` format, without throwing.
JsonResult!T fromJSON(T)(JSONValue json)
{
    alias U = Unqual!T;

    static if (hasConvert!(Json, U))
        return decodeVia!(convertOf!(Json, U), U)(json);

    else static if (is(U == bool))
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
        return decodeEnumWith!(U, resolveRepr!(Json, U), resolveCaseStyle!(Json, U))(json);

    else static if (isIntegral!U)
        return decodeIntegral!T(json);

    else static if (isFloatingPoint!U)
    {
        switch (json.type)
        {
            case JSONType.float_:   return ok!Exception(cast(T) json.floating);
            case JSONType.integer:  return ok!Exception(cast(T) json.integer);
            case JSONType.uinteger: return ok!Exception(cast(T) json.uinteger);
            default:
                return fail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON number");
        }
    }

    else static if (is(U == E[], E))
    {
        static if (isSomeChar!E)
        {
            auto s = fromJSON!string(json);
            if (s.hasError)
                return err!T(s.error);
            import std.conv : to;
            return ok!Exception(s.value.to!U);
        }
        else
        {
            if (json.type != JSONType.array)
                return fail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON array");
            U result;
            foreach (elem; json.array)
            {
                auto r = fromJSON!E(elem);
                if (r.hasError)
                    return err!T(r.error);
                result ~= r.value;
            }
            return ok!Exception(result);
        }
    }

    else static if (is(U == V[K], V, K))
        return decodeAA!U(json);

    else static if (is(U == Nullable!N, N))
    {
        if (json.type == JSONType.null_)
            return ok!Exception(U.init);
        auto r = fromJSON!N(json);
        if (r.hasError)
            return err!T(r.error);
        return ok!Exception(U(r.value));
    }

    else static if (is(U == Ternary))
    {
        switch (json.type)
        {
            case JSONType.null_:  return ok!Exception(Ternary.unknown);
            case JSONType.true_:  return ok!Exception(Ternary.yes);
            case JSONType.false_: return ok!Exception(Ternary.no);
            default:
                return fail!T("Cannot decode Ternary at $: expected null, true, or false");
        }
    }

    else static if (is(U == SysTime))
    {
        if (json.type != JSONType.string)
            return fail!T("Cannot decode SysTime at $: expected a JSON string");
        if (!hasZoneOffset(json.str))
            return fail!T(
                "Cannot decode SysTime at $: timestamp must include an explicit UTC marker or offset");
        try
            return ok!Exception(SysTime.fromISOExtString(json.str).toUTC);
        catch (Exception e)
            return fail!T("Cannot decode SysTime at $: " ~ e.msg);
    }

    else static if (isSumType!U)
        return decodeSumType!(U, MatchStrategy.exactlyOne)(json);

    else static if (is(U == struct))
        return decodeStruct!T(json);

    else
        static assert(false, "wired: unsupported type for fromJSON: " ~ T.stringof);
}

/// True when an ISO-8601 extended timestamp carries an explicit zone — a `Z` or a
/// numeric `±HH:MM` offset in the time portion (after the `T`). §4.4 rejects
/// offsetless timestamps.
private bool hasZoneOffset(string s)
{
    import std.string : indexOf;
    import std.algorithm : canFind;

    const t = s.indexOf('T');
    if (t < 0)
        return false;
    const time = s[t + 1 .. $];
    return time.canFind('Z') || time.canFind('+') || time.canFind('-');
}

/// Decodes a `SumType` by probing each variant (declaration order). `exactlyOne`
/// requires a single match (zero → no-match, many → ambiguity); `first` takes the
/// first success (§4.7).
private JsonResult!ST decodeSumType(ST, MatchStrategy strat)(JSONValue json)
if (isSumType!ST)
{
    alias Types = TemplateArgsOf!ST;

    static if (strat == MatchStrategy.first)
    {
        static foreach (V; Types)
        {{
            auto r = fromJSON!V(json);
            if (r.hasValue)
                return ok!Exception(ST(r.value));
        }}
        return fail!ST("Cannot decode " ~ ST.stringof ~ " at $: no variant matched");
    }
    else
    {
        ST result;
        size_t matches = 0;
        static foreach (V; Types)
        {{
            auto r = fromJSON!V(json);
            if (r.hasValue)
            {
                matches++;
                result = ST(r.value);
            }
        }}
        if (matches == 1)
            return ok!Exception(result);
        if (matches == 0)
            return fail!ST("Cannot decode " ~ ST.stringof ~ " at $: no variant matched");
        return fail!ST(
            "Cannot decode " ~ ST.stringof ~ " at $: ambiguous — multiple variants matched");
    }
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

private JsonResult!E decodeEnumWith(E, Repr repr, CaseStyle style)(JSONValue json)
if (is(E == enum))
{
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
        if (json.type != JSONType.string)
            return fail!E("Cannot decode " ~ E.stringof ~ " at $: expected a JSON string");

        static foreach (m; __traits(allMembers, E))
            if (json.str == wireName!(Json, __traits(getMember, E, m), style))
                return ok!Exception(__traits(getMember, E, m));

        return fail!E(
            "Cannot decode " ~ E.stringof ~ " at $ from JSON string \"" ~ json.str
            ~ "\": expected one of: " ~ nameList!(E, style));
    }
}

private JsonResult!T decodeStruct(T)(JSONValue json)
if (is(T == struct))
{
    enum _uniq = checkUniqueFieldKeys!(Json, T);

    if (json.type != JSONType.object)
        return fail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON object");

    enum aggStyle = resolveCaseStyle!(Json, T);
    T result;
    static foreach (i; 0 .. T.tupleof.length)
    {{
        enum key = wireName!(Json, T.tupleof[i], aggStyle);
        if (auto p = key in json.object)
        {
            auto r = decodeFieldValue!(T, i)(*p);
            if (r.hasError)
                return err!T(r.error);
            result.tupleof[i] = r.value;
        }
        else static if (isNullAware!(typeof(T.tupleof[i])))
        {
            // A missing null-aware field decodes to its empty value, which the
            // `T result;` default already holds (§4.5).
        }
        else
            return fail!T(
                "Cannot decode " ~ T.stringof ~ " at $." ~ key ~ ": missing required field");
    }}
    return ok!Exception(result);
}

private JsonResult!(typeof(T.tupleof[i])) decodeFieldValue(T, size_t i)(JSONValue json)
{
    alias V = typeof(T.tupleof[i]);

    static if (hasConvert!(Json, T.tupleof[i]))
        return decodeVia!(convertOf!(Json, T.tupleof[i]), V)(json);

    else static if (is(V == enum))
        return decodeEnumWith!(V,
            resolveReprFor!(Json, WireTarget.all, T.tupleof[i], V),
            resolveCaseFor!(Json, WireTarget.all, T.tupleof[i], V))(json);

    else static if (is(V == E[], E) && is(E == enum))
    {
        if (json.type != JSONType.array)
            return fail!V("Cannot decode " ~ V.stringof ~ " at $: expected a JSON array");
        V result;
        foreach (elem; json.array)
        {
            auto r = decodeEnumWith!(E,
                resolveReprFor!(Json, WireTarget.value, T.tupleof[i], E),
                resolveCaseFor!(Json, WireTarget.value, T.tupleof[i], E))(elem);
            if (r.hasError)
                return err!V(r.error);
            result ~= r.value;
        }
        return ok!Exception(result);
    }

    else static if (isSumType!V)
        return decodeSumType!(V, resolveMatch!(Json, T.tupleof[i]))(json);

    else
        return fromJSON!V(json);
}

/// True for the null-aware wrapper types whose empty value maps to JSON `null`
/// and whose missing key decodes to that empty value (§4.5).
private enum bool isNullAware(V) = is(V == Nullable!N, N) || is(V == Ternary);

/// Duck-types the `expected` result so a converter may return either a plain
/// value or an `Expected!(Value, Exception)` (§8).
private enum bool isExpectedLike(X) =
    __traits(hasMember, X, "hasValue") && __traits(hasMember, X, "hasError")
    && __traits(hasMember, X, "value") && __traits(hasMember, X, "error");

/// Encodes `value` through the resolved `@WireConvert` `Conv`: `toWire(value)` is
/// encoded normally; an `Expected`-returning `toWire` is unwrapped, its failure
/// propagated (§8).
private JsonResult!JSONValue encodeVia(alias Conv, V)(const V value)
{
    auto wire = Conv.to(value);
    static if (isExpectedLike!(typeof(wire)))
    {
        if (wire.hasError)
            return err!JSONValue(wire.error);
        return toJSON(wire.value);
    }
    else
        return toJSON(wire);
}

/// Decodes into `V` through the resolved `@WireConvert` `Conv`: the wire type is
/// inferred from `toWire`'s return for `V`, decoded, then passed to `fromWire`
/// (§8). A serialize-only converter (no `fromWire`) is unsupported at compile time.
private JsonResult!V decodeVia(alias Conv, V)(JSONValue json)
{
    static assert(!is(Conv.from == void),
        "wired: a serialize-only @WireConvert cannot decode " ~ V.stringof);

    alias Raw = typeof(Conv.to(V.init));
    static if (isExpectedLike!Raw)
        alias WireT = typeof(Raw.init.value);
    else
        alias WireT = Raw;

    auto raw = fromJSON!WireT(json);
    if (raw.hasError)
        return err!V(raw.error);

    auto back = Conv.from(raw.value);
    static if (isExpectedLike!(typeof(back)))
    {
        if (back.hasError)
            return err!V(back.error);
        return ok!Exception(back.value);
    }
    else
        return ok!Exception(back);
}

private JsonResult!JSONValue encodeAA(T)(const T value)
if (is(T == V[K], V, K))
{
    alias V = typeof(T.init.values[0]);
    JSONValue[string] obj;
    foreach (k, ref v; value)
    {
        auto rv = toJSON(v);
        if (rv.hasError)
            return err!JSONValue(rv.error);
        obj[aaKeyText(k)] = rv.value;
    }
    return ok!Exception(JSONValue(obj));
}

private JsonResult!T decodeAA(T)(JSONValue json)
if (is(T == V[K], V, K))
{
    alias V = typeof(T.init.values[0]);
    alias K = typeof(T.init.keys[0]);

    if (json.type != JSONType.object)
        return fail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON object");

    T result;
    foreach (keyStr, jval; json.object)
    {
        auto k = aaKeyParse!K(keyStr);
        if (k.hasError)
            return err!T(k.error);
        auto rv = fromJSON!V(jval);
        if (rv.hasError)
            return err!T(rv.error);
        result[k.value] = rv.value;
    }
    return ok!Exception(result);
}

/// The JSON object-key text for an associative-array key: a `string` verbatim,
/// or an enum by its resolved name / underlying-value text (§7).
private string aaKeyText(K)(K k)
{
    static if (is(K == string))
        return k;
    else static if (is(K == enum))
    {
        enum repr = resolveRepr!(Json, K);
        static if (repr == Repr.name)
        {
            enum style = resolveCaseStyle!(Json, K);
            static foreach (m; __traits(allMembers, K))
                if (k == __traits(getMember, K, m))
                    return wireName!(Json, __traits(getMember, K, m), style);
            assert(0, "aaKeyText: value is not a declared enum member");
        }
        else
        {
            auto orig = cast(OriginalType!K) k;
            static if (is(OriginalType!K == string))
                return orig;
            else
            {
                import std.conv : to;
                return orig.to!string;
            }
        }
    }
    else
        static assert(false, "wired: associative-array keys must be string or enum, not " ~ K.stringof);
}

/// Parses an associative-array key from its JSON object-key text — the inverse of
/// $(LREF aaKeyText).
private JsonResult!K aaKeyParse(K)(string keyStr)
{
    static if (is(K == string))
        return ok!Exception(keyStr);
    else static if (is(K == enum))
    {
        enum repr = resolveRepr!(Json, K);
        static if (repr == Repr.name)
        {
            enum style = resolveCaseStyle!(Json, K);
            static foreach (m; __traits(allMembers, K))
                if (keyStr == wireName!(Json, __traits(getMember, K, m), style))
                    return ok!Exception(__traits(getMember, K, m));
            return fail!K(
                "Cannot decode " ~ K.stringof ~ " key \"" ~ keyStr
                ~ "\": expected one of: " ~ nameList!(K, style));
        }
        else
        {
            import std.conv : to, ConvException;

            OriginalType!K orig;
            static if (is(OriginalType!K == string))
                orig = keyStr;
            else
            {
                try
                    orig = keyStr.to!(OriginalType!K);
                catch (ConvException e)
                    return fail!K("Cannot decode " ~ K.stringof ~ " key \"" ~ keyStr ~ "\": " ~ e.msg);
            }
            auto member = enumFromValue!K(orig);
            if (member.hasError)
                return fail!K("Cannot decode " ~ K.stringof ~ " key \"" ~ keyStr ~ "\": " ~ member.error.context);
            return ok!Exception(member.value);
        }
    }
    else
        static assert(false, "wired: associative-array keys must be string or enum, not " ~ K.stringof);
}

/// The comma-joined resolved member names of `E` under `Json` at case `style`,
/// for the `"expected one of: …"` decode-error context.
private template nameList(E, CaseStyle style)
if (is(E == enum))
{
    enum string nameList = () {
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

@("wired.json.enumByNameAndValue")
@safe unittest
{
    @WireCase!Json(CaseStyle.snakeCase)
    enum Mode
    {
        fastPath,
        @WireName!Json("turbo") slowPath,
    }

    assert(toJSON(Mode.fastPath).value == JSONValue("fast_path"));
    assert(toJSON(Mode.slowPath).value == JSONValue("turbo"));
    assert(fromJSON!Mode(JSONValue("fast_path")).value == Mode.fastPath);
    assert(fromJSON!Mode(JSONValue("turbo")).value == Mode.slowPath);
    assert(fromJSON!Mode(JSONValue("nope")).hasError);

    @WireRepr!Json(Repr.value)
    enum Priority { low = 1, high = 5 }

    assert(toJSON(Priority.high).value == JSONValue(5));
    assert(fromJSON!Priority(JSONValue(5)).value == Priority.high);
    assert(fromJSON!Priority(JSONValue(2)).hasError);
}

@("wired.json.arrays")
@system unittest
{
    assert(toJSON([1, 2, 3]).value == JSONValue([1, 2, 3]));
    assert(fromJSON!(int[])(JSONValue([1, 2, 3])).value == [1, 2, 3]);
    assert(fromJSON!(int[])(JSONValue(4)).hasError);

    enum Suit { spades, hearts }
    assert(toJSON([Suit.spades, Suit.hearts]).value == JSONValue(["spades", "hearts"]));
    assert(fromJSON!(Suit[])(JSONValue(["hearts", "spades"])).value == [Suit.hearts, Suit.spades]);
}

@("wired.json.aggregate")
@system unittest
{
    static struct Server
    {
        string host;
        ushort port;
    }

    auto s = Server("localhost", 8080);
    auto json = toJSON(s).value;
    assert(json.type == JSONType.object);
    assert(json["host"] == JSONValue("localhost"));
    assert(json["port"] == JSONValue(8080));

    assert(fromJSON!Server(json).value == s);

    // Missing required field is a decode error naming the path.
    auto bad = fromJSON!Server(parseObject(`{"host":"x"}`));
    assert(bad.hasError);
}

@("wired.json.aggregateFieldPolicy")
@system unittest
{
    struct Toml {}

    @WireCase!Json(CaseStyle.snakeCase)
    static struct Config
    {
        @WireName!Json("db_host") string dbHost;
        int retryCount;
    }

    auto c = Config("h", 3);
    auto json = toJSON(c).value;
    assert(json["db_host"] == JSONValue("h"));     // field WireName wins
    assert(json["retry_count"] == JSONValue(3));    // aggregate snake_case recasing
    assert(fromJSON!Config(json).value == c);
}

@("wired.json.fieldEnumOverride")
@system unittest
{
    enum Mode { fastPath, slowPath }

    static struct S
    {
        @WireCase!Json(CaseStyle.kebabCase) Mode m;
    }

    // The field-level WireCase overrides the (absent) type policy for the enum.
    assert(toJSON(S(Mode.fastPath)).value["m"] == JSONValue("fast-path"));
    assert(fromJSON!S(toJSON(S(Mode.slowPath)).value).value == S(Mode.slowPath));
}

@("wired.json.nullableAndTernary")
@system unittest
{
    // Nullable round-trips through JSON null / value.
    assert(toJSON(Nullable!int.init).value == JSONValue(null));
    assert(toJSON(Nullable!int(7)).value == JSONValue(7));
    assert(fromJSON!(Nullable!int)(JSONValue(null)).value.isNull);
    assert(fromJSON!(Nullable!int)(JSONValue(7)).value.get == 7);

    // Ternary ⇄ null/true/false.
    assert(toJSON(Ternary.unknown).value == JSONValue(null));
    assert(toJSON(Ternary.yes).value == JSONValue(true));
    assert(fromJSON!Ternary(JSONValue(null)).value == Ternary.unknown);
    assert(fromJSON!Ternary(JSONValue(false)).value == Ternary.no);

    // A missing null-aware field decodes to its empty value.
    static struct S { int a; Nullable!int b; Ternary c; }
    auto r = fromJSON!S(parseObject(`{"a":1}`));
    assert(r.value.a == 1 && r.value.b.isNull && r.value.c == Ternary.unknown);
}

@("wired.json.sysTime")
@system unittest
{
    auto t = SysTime.fromISOExtString("2026-07-01T12:30:00Z");
    auto json = toJSON(t).value;
    assert(json.type == JSONType.string);
    assert(fromJSON!SysTime(json).value == t.toUTC);

    // Offsetless timestamps are rejected.
    assert(fromJSON!SysTime(JSONValue("2026-07-01T12:30:00")).hasError);
}

@("wired.json.sumType")
@system unittest
{
    alias Cell = SumType!(int, string);

    assert(toJSON(Cell(42)).value == JSONValue(42));
    assert(toJSON(Cell("hi")).value == JSONValue("hi"));
    assert(fromJSON!Cell(JSONValue(42)).value == Cell(42));
    assert(fromJSON!Cell(JSONValue("hi")).value == Cell("hi"));

    // exactlyOne (default) rejects when no variant matches.
    assert(fromJSON!Cell(JSONValue(true)).hasError);

    // Field-level @(WireMatch.first) picks the first matching arm.
    static struct Row
    {
        @(WireMatch.first!Json) SumType!(int, double) cell;
    }
    auto r = fromJSON!Row(parseObject(`{"cell":42}`));
    assert(r.value.cell == SumType!(int, double)(42));
}

@("wired.json.associativeArrays")
@system unittest
{
    // String-keyed AA.
    auto m = ["a": 1, "b": 2];
    assert(fromJSON!(int[string])(toJSON(m).value).value == m);

    // Enum-keyed AA by member name (default).
    enum Suit { spades, hearts }
    auto byName = [Suit.spades: 1, Suit.hearts: 2];
    auto jn = toJSON(byName).value;
    assert(jn["spades"] == JSONValue(1) && jn["hearts"] == JSONValue(2));
    assert(fromJSON!(int[Suit])(jn).value == byName);

    // Enum-keyed AA by underlying value.
    @WireRepr!Json(Repr.value)
    enum Priority { low = 1, high = 5 }
    auto byVal = [Priority.low: "lo", Priority.high: "hi"];
    auto jv = toJSON(byVal).value;
    assert(jv["1"] == JSONValue("lo") && jv["5"] == JSONValue("hi"));
    assert(fromJSON!(string[Priority])(jv).value == byVal);
}

@("wired.json.wireConvert")
@system unittest
{
    import core.time : Duration, msecs;

    static struct Timer
    {
        @WireConvert!(d => d.total!"msecs", ms => msecs(ms))
        Duration timeout;
    }

    auto t = Timer(1500.msecs);
    auto json = toJSON(t).value;
    assert(json["timeout"] == JSONValue(1500)); // Duration encoded as its ms count
    assert(fromJSON!Timer(json).value == t);     // round-trips back to a Duration
}

version (unittest) private JSONValue parseObject(string s)
{
    import std.json : parseJSON;
    return parseJSON(s);
}
