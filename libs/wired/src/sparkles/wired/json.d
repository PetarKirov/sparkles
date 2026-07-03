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
import std.json : JSONValue, JSONType, parseJSON;
import std.sumtype : isSumType, match, SumType;
import std.traits : isFloatingPoint, isIntegral, isSomeChar, OriginalType,
    TemplateArgsOf, Unqual;
import std.typecons : Nullable, Ternary;

import expected : Expected, ok, err;
import optional : Optional, some;

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

/// Internal walk result: a value or an `Exception`, with none of `Expected`'s
/// hook and introspection machinery — one `Expected!(T, Exception)` drags in
/// roughly 25–30 nested instantiations per distinct `T`. The recursive walk
/// passes `Res` and the public entry points convert at the boundary, so the
/// `Expected` cost is paid once per public call type instead of once per node
/// type. §9 still holds: nothing here throws.
private struct Res(T)
{
    Exception error;
    T value;
}

private Res!T resOk(T)(T value) => Res!T(null, value);
private Res!T resFail(T)(string msg) => Res!T(new Exception(msg));

/// Converts an internal `Res` into the public `Expected`-based result.
private JsonResult!T toResult(T)(Res!T r)
    => r.error is null ? ok!Exception(r.value) : err!T(r.error);

// ─────────────────────────────────────────────────────────────────────────────
// Encoding
// ─────────────────────────────────────────────────────────────────────────────

/// Encodes `value` into a `JSONValue` under the `Json` format, without throwing.
JsonResult!JSONValue toJSON(T)(const T value)
    => encodeImpl(value).toResult;

/// The recursive encode walk, on the lightweight `Res` channel.
private Res!JSONValue encodeImpl(T)(const T value)
{
    alias U = Unqual!T;

    static if (is(U == JSONValue))
    {
        JSONValue v = value; // mutable copy of the passed-through value
        return resOk(v);
    }

    else static if (hasConvert!(Json, U))
        return encodeVia!(convertOf!(Json, U), U)(value);

    else static if (is(U == bool) || is(U == string))
        return resOk(JSONValue(value));

    else static if (is(U == enum))
        return encodeEnumWith!(U, resolveRepr!(Json, U), resolveCaseStyle!(Json, U))(value);

    else static if (isIntegral!U)
        return resOk(JSONValue(value));

    else static if (isFloatingPoint!U)
    {
        import std.math : isFinite;

        if (!isFinite(value))
            return resFail!JSONValue(
                "Cannot encode " ~ T.stringof ~ " at $: NaN and infinity are not representable in JSON");
        return resOk(JSONValue(value));
    }

    else static if (is(U == E[], E))
    {
        static if (isSomeChar!E)
            return resOk(JSONValue(value.idup));
        else
        {
            JSONValue[] arr;
            foreach (e; value)
            {
                auto r = encodeImpl(e);
                if (r.error !is null)
                    return r;
                arr ~= r.value;
            }
            return resOk(JSONValue(arr));
        }
    }

    else static if (is(U == V[K], V, K))
        return encodeAA(value);

    else static if (is(U == Nullable!N, N))
    {
        if (value.isNull)
            return resOk(JSONValue(null));
        return encodeImpl(value.get);
    }

    else static if (is(U == Optional!N, N))
    {
        if (value.empty)
            return resOk(JSONValue(null));
        return encodeImpl(value.front);
    }

    else static if (is(U == Ternary))
    {
        if (value == Ternary.unknown)
            return resOk(JSONValue(null));
        return resOk(JSONValue(value == Ternary.yes));
    }

    else static if (is(U == SysTime))
        return resOk(JSONValue(value.toUTC.toISOExtString));

    else static if (isSumType!U)
        return value.match!(v => encodeImpl(v));

    else static if (is(U == struct))
        return encodeStruct(value);

    else
        static assert(false, "wired: unsupported type for toJSON: " ~ T.stringof);
}

private Res!JSONValue encodeEnumWith(E, Repr repr, CaseStyle style)(const E value)
if (is(E == enum))
{
    static if (repr == Repr.value)
        return encodeImpl(cast(OriginalType!E) value);
    else
    {
        alias names = wireNames!(Json, E, style);
        static foreach (i, m; __traits(allMembers, E))
            if (value == __traits(getMember, E, m))
                return resOk(JSONValue(names[i]));

        return resFail!JSONValue(
            "Cannot encode " ~ E.stringof ~ " at $: value is not a declared member");
    }
}

/// Encodes a struct field by field, dispatching each on its policy inline —
/// converts, then the field's value-slot enum policy at the field and one
/// wrapper level, then the type-level walk. The dispatch lives in the loop body
/// (rather than a per-field helper template) so a plain field costs no
/// per-field instantiation and policy-carrying fields share the value-keyed
/// `encodeEnumWith`/`encodeEnumArray` instantiations.
private Res!JSONValue encodeStruct(T)(const T value)
if (is(T == struct))
{
    alias policies = fieldPolicies!(Json, T);

    JSONValue[string] obj;
    static foreach (i; 0 .. policies.length)
    {{
        alias V = typeof(T.tupleof[i]);

        // The §5.4 encode-omission test for this field's skip policy.
        static if (policies[i].skip == WireSkip.never)
            enum bool omitted = false;
        else static if (policies[i].skip == WireSkip.whenDefault)
            const bool omitted = value.tupleof[i] == T.init.tupleof[i];
        else
            const bool omitted = isEmptyValue(value.tupleof[i]);

        if (!omitted)
        {
            static if (policies[i].hasConvert)
                auto r = encodeVia!(convertOf!(Json, T.tupleof[i]), V)(value.tupleof[i]);
            else static if (is(V == enum))
                auto r = encodeEnumWith!(V,
                    policies[i].reprFor(WireTarget.all, resolveRepr!(Json, V)),
                    policies[i].caseFor(WireTarget.all, resolveCaseStyle!(Json, V)))(
                    value.tupleof[i]);
            else static if (is(V == E[], E) && is(E == enum))
                auto r = encodeEnumArray!(E,
                    policies[i].reprFor(WireTarget.value, resolveRepr!(Json, E)),
                    policies[i].caseFor(WireTarget.value, resolveCaseStyle!(Json, E)))(
                    value.tupleof[i]);
            else
                auto r = encodeImpl(value.tupleof[i]);

            if (r.error !is null)
                return r;
            obj[policies[i].key] = r.value;
        }
    }}
    return resOk(JSONValue(obj));
}

private Res!JSONValue encodeEnumArray(E, Repr repr, CaseStyle style)(const E[] values)
if (is(E == enum))
{
    JSONValue[] arr;
    foreach (e; values)
    {
        auto r = encodeEnumWith!(E, repr, style)(e);
        if (r.error !is null)
            return r;
        arr ~= r.value;
    }
    return resOk(JSONValue(arr));
}

// ─────────────────────────────────────────────────────────────────────────────
// File helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Reads UTF-8 from `path`, parses it, and decodes it into a `T` — without
/// throwing (§4.1). The error identifies the failing stage (read, parse, decode).
JsonResult!T readJSONFile(T)(string path)
{
    import std.file : readText;

    string text;
    try
        text = readText(path);
    catch (Exception e)
        return fail!T("Cannot read " ~ path ~ ": " ~ e.msg);

    JSONValue json;
    try
        json = parseJSON(text);
    catch (Exception e)
        return fail!T("Cannot parse " ~ path ~ ": " ~ e.msg);

    auto r = fromJSON!T(json);
    if (r.hasError)
        return fail!T("Cannot decode " ~ path ~ ": " ~ r.error.msg);
    return r;
}

/// Encodes `value` and writes it to `path` atomically (temp file in the same
/// directory + rename) with a trailing newline, creating missing parent
/// directories — without throwing (§4.1). `compact` selects single-line vs pretty
/// rendering; both use `doNotEscapeSlashes`.
JsonResult!void writeJSONFile(T)(const T value, string path, bool compact = false)
{
    import std.file : mkdirRecurse, rename, write;
    import std.json : JSONOptions;
    import std.path : dirName;

    auto enc = toJSON(value);
    if (enc.hasError)
        return err!void(enc.error);

    string text = compact
        ? enc.value.toString(JSONOptions.doNotEscapeSlashes)
        : enc.value.toPrettyString(JSONOptions.doNotEscapeSlashes);
    text ~= "\n";

    const dir = path.dirName;
    try
    {
        if (dir.length && dir != ".")
            mkdirRecurse(dir);
    }
    catch (Exception e)
        return err!void(new Exception(
            "Cannot create parent directory of " ~ path ~ ": " ~ e.msg));

    const tmp = path ~ ".wired-tmp";
    try
    {
        write(tmp, text);
        rename(tmp, path);
    }
    catch (Exception e)
        return err!void(new Exception("Cannot write " ~ path ~ ": " ~ e.msg));

    return ok!Exception();
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

/// Decodes a `JSONValue` into a `T` under the `Json` format, without throwing.
JsonResult!T fromJSON(T)(JSONValue json)
    => decodeImpl!T(json).toResult;

/// The recursive decode walk, on the lightweight `Res` channel.
private Res!T decodeImpl(T)(JSONValue json)
{
    alias U = Unqual!T;

    static if (is(U == JSONValue))
        return resOk(json);

    else static if (hasConvert!(Json, U))
        return decodeVia!(convertOf!(Json, U), U)(json);

    else static if (is(U == bool))
    {
        if (json.type != JSONType.true_ && json.type != JSONType.false_)
            return resFail!T("Cannot decode bool at $: expected a JSON boolean");
        return resOk(json.boolean);
    }

    else static if (is(U == string))
    {
        if (json.type != JSONType.string)
            return resFail!T("Cannot decode string at $: expected a JSON string");
        return resOk(json.str);
    }

    else static if (is(U == enum))
        return decodeEnumWith!(U, resolveRepr!(Json, U), resolveCaseStyle!(Json, U))(json);

    else static if (isIntegral!U)
        return decodeIntegral!T(json);

    else static if (isFloatingPoint!U)
    {
        switch (json.type)
        {
            case JSONType.float_:   return resOk(cast(T) json.floating);
            case JSONType.integer:  return resOk(cast(T) json.integer);
            case JSONType.uinteger: return resOk(cast(T) json.uinteger);
            default:
                return resFail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON number");
        }
    }

    else static if (is(U == E[], E))
    {
        static if (isSomeChar!E)
        {
            auto s = decodeImpl!string(json);
            if (s.error !is null)
                return Res!T(s.error);
            import std.conv : to;
            return resOk(s.value.to!U);
        }
        else
        {
            if (json.type != JSONType.array)
                return resFail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON array");
            U result;
            foreach (elem; json.array)
            {
                auto r = decodeImpl!E(elem);
                if (r.error !is null)
                    return Res!T(r.error);
                result ~= r.value;
            }
            return resOk(result);
        }
    }

    else static if (is(U == V[K], V, K))
        return decodeAA!U(json);

    else static if (is(U == Nullable!N, N))
    {
        if (json.type == JSONType.null_)
            return resOk(U.init);
        auto r = decodeImpl!N(json);
        if (r.error !is null)
            return Res!T(r.error);
        return resOk(U(r.value));
    }

    else static if (is(U == Optional!N, N))
    {
        if (json.type == JSONType.null_)
            return resOk(U.init);
        auto r = decodeImpl!N(json);
        if (r.error !is null)
            return Res!T(r.error);
        return resOk(some(r.value));
    }

    else static if (is(U == Ternary))
    {
        switch (json.type)
        {
            case JSONType.null_:  return resOk(Ternary.unknown);
            case JSONType.true_:  return resOk(Ternary.yes);
            case JSONType.false_: return resOk(Ternary.no);
            default:
                return resFail!T("Cannot decode Ternary at $: expected null, true, or false");
        }
    }

    else static if (is(U == SysTime))
    {
        if (json.type != JSONType.string)
            return resFail!T("Cannot decode SysTime at $: expected a JSON string");
        if (!hasZoneOffset(json.str))
            return resFail!T(
                "Cannot decode SysTime at $: timestamp must include an explicit UTC marker or offset");
        try
            return resOk(SysTime.fromISOExtString(json.str).toUTC);
        catch (Exception e)
            return resFail!T("Cannot decode SysTime at $: " ~ e.msg);
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
private Res!ST decodeSumType(ST, MatchStrategy strat)(JSONValue json)
if (isSumType!ST)
{
    alias Types = TemplateArgsOf!ST;

    static if (strat == MatchStrategy.first)
    {
        static foreach (V; Types)
        {{
            auto r = decodeImpl!V(json);
            if (r.error is null)
                return resOk(ST(r.value));
        }}
        return resFail!ST("Cannot decode " ~ ST.stringof ~ " at $: no variant matched");
    }
    else
    {
        ST result;
        size_t matches = 0;
        static foreach (V; Types)
        {{
            auto r = decodeImpl!V(json);
            if (r.error is null)
            {
                matches++;
                result = ST(r.value);
            }
        }}
        if (matches == 1)
            return resOk(result);
        if (matches == 0)
            return resFail!ST("Cannot decode " ~ ST.stringof ~ " at $: no variant matched");
        return resFail!ST(
            "Cannot decode " ~ ST.stringof ~ " at $: ambiguous — multiple variants matched");
    }
}

private Res!T decodeIntegral(T)(JSONValue json)
{
    static if (__traits(isUnsigned, T))
    {
        if (json.type == JSONType.uinteger)
        {
            if (json.uinteger > T.max)
                return resFail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return resOk(cast(T) json.uinteger);
        }
        if (json.type == JSONType.integer)
        {
            if (json.integer < 0 || json.integer > T.max)
                return resFail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return resOk(cast(T) json.integer);
        }
    }
    else
    {
        if (json.type == JSONType.integer)
        {
            if (json.integer < T.min || json.integer > T.max)
                return resFail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return resOk(cast(T) json.integer);
        }
        if (json.type == JSONType.uinteger)
        {
            if (json.uinteger > T.max)
                return resFail!T("Cannot decode " ~ T.stringof ~ " at $: value out of range");
            return resOk(cast(T) json.uinteger);
        }
    }
    return resFail!T("Cannot decode " ~ T.stringof ~ " at $: expected an integer");
}

private Res!E decodeEnumWith(E, Repr repr, CaseStyle style)(JSONValue json)
if (is(E == enum))
{
    static if (repr == Repr.value)
    {
        auto orig = decodeImpl!(OriginalType!E)(json);
        if (orig.error !is null)
            return Res!E(orig.error);
        auto member = enumFromValue!E(orig.value);
        if (member.hasError)
            return resFail!E("Cannot decode " ~ E.stringof ~ " at $: " ~ member.error.context);
        return resOk(member.value);
    }
    else
    {
        if (json.type != JSONType.string)
            return resFail!E("Cannot decode " ~ E.stringof ~ " at $: expected a JSON string");

        alias names = wireNames!(Json, E, style);
        static foreach (i, m; __traits(allMembers, E))
            if (json.str == names[i])
                return resOk(__traits(getMember, E, m));

        return resFail!E(
            "Cannot decode " ~ E.stringof ~ " at $ from JSON string \"" ~ json.str
            ~ "\": expected one of: " ~ nameList!(E, style));
    }
}

/// Decodes a struct field by field, dispatching each on its policy inline —
/// see `encodeStruct` for why the dispatch is not a per-field helper template.
private Res!T decodeStruct(T)(JSONValue json)
if (is(T == struct))
{

    if (json.type != JSONType.object)
        return resFail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON object");

    alias policies = fieldPolicies!(Json, T);
    T result;
    static foreach (i; 0 .. policies.length)
    {{
        alias V = typeof(T.tupleof[i]);

        if (auto p = policies[i].key in json.object)
        {
            static if (policies[i].hasConvert)
                auto r = decodeVia!(convertOf!(Json, T.tupleof[i]), V)(*p);
            else static if (is(V == enum))
                auto r = decodeEnumWith!(V,
                    policies[i].reprFor(WireTarget.all, resolveRepr!(Json, V)),
                    policies[i].caseFor(WireTarget.all, resolveCaseStyle!(Json, V)))(*p);
            else static if (is(V == E[], E) && is(E == enum))
                auto r = decodeEnumArray!(E,
                    policies[i].reprFor(WireTarget.value, resolveRepr!(Json, E)),
                    policies[i].caseFor(WireTarget.value, resolveCaseStyle!(Json, E)))(*p);
            else static if (isSumType!V)
                auto r = decodeSumType!(V, policies[i].match)(*p);
            else
                auto r = decodeImpl!V(*p);

            if (r.error !is null)
            {
                // A present but invalid value under `useDefault` leaves the field
                // at its default (§5.4); otherwise the failure propagates.
                static if (!(policies[i].optional
                    && policies[i].onInvalid == WireInvalid.useDefault))
                    return Res!T(r.error);
            }
            else
                result.tupleof[i] = r.value;
        }
        else static if (isNullAware!V || policies[i].optional)
        {
            // A missing null-aware or @WireOptional field decodes to its default,
            // which the `T result;` default already holds (§4.5, §5.4).
        }
        else
            return resFail!T(
                "Cannot decode " ~ T.stringof ~ " at $." ~ policies[i].key
                ~ ": missing required field");
    }}
    return resOk(result);
}

private Res!(E[]) decodeEnumArray(E, Repr repr, CaseStyle style)(JSONValue json)
if (is(E == enum))
{
    if (json.type != JSONType.array)
        return resFail!(E[])("Cannot decode " ~ (E[]).stringof ~ " at $: expected a JSON array");
    E[] result;
    foreach (elem; json.array)
    {
        auto r = decodeEnumWith!(E, repr, style)(elem);
        if (r.error !is null)
            return Res!(E[])(r.error);
        result ~= r.value;
    }
    return resOk(result);
}

/// True for the null-aware wrapper types whose empty value maps to JSON `null`
/// and whose missing key decodes to that empty value (§4.5).
private enum bool isNullAware(V) =
    is(V == Nullable!N, N) || is(V == Optional!O, O) || is(V == Ternary);

/// Whether a null-aware value is empty — the `WireSkip.whenEmpty` test (§5.4).
/// Keyed by the value type alone so same-typed fields share one instantiation;
/// the `never` and `whenDefault` policies are handled inline in `encodeStruct`.
private bool isEmptyValue(V)(const V value)
{
    static if (is(V == Nullable!N, N))
        return value.isNull;
    else static if (is(V == Optional!O, O))
        return value.empty;
    else static if (is(V == Ternary))
        return value == Ternary.unknown;
    else
        return false;
}

/// Duck-types the `expected` result so a converter may return either a plain
/// value or an `Expected!(Value, Exception)` (§8).
private enum bool isExpectedLike(X) =
    __traits(hasMember, X, "hasValue") && __traits(hasMember, X, "hasError")
    && __traits(hasMember, X, "value") && __traits(hasMember, X, "error");

/// Encodes `value` through the resolved `@WireConvert` `Conv`: `toWire(value)` is
/// encoded normally; an `Expected`-returning `toWire` is unwrapped, its failure
/// propagated (§8).
private Res!JSONValue encodeVia(alias Conv, V)(const V value)
{
    auto wire = Conv.to(value);
    static if (isExpectedLike!(typeof(wire)))
    {
        if (wire.hasError)
            return Res!JSONValue(wire.error);
        return encodeImpl(wire.value);
    }
    else
        return encodeImpl(wire);
}

/// Decodes into `V` through the resolved `@WireConvert` `Conv`: the wire type is
/// inferred from `toWire`'s return for `V`, decoded, then passed to `fromWire`
/// (§8). A serialize-only converter (no `fromWire`) is unsupported at compile time.
private Res!V decodeVia(alias Conv, V)(JSONValue json)
{
    static assert(!is(Conv.from == void),
        "wired: a serialize-only @WireConvert cannot decode " ~ V.stringof);

    alias Raw = typeof(Conv.to(V.init));
    static if (isExpectedLike!Raw)
        alias WireT = typeof(Raw.init.value);
    else
        alias WireT = Raw;

    auto raw = decodeImpl!WireT(json);
    if (raw.error !is null)
        return Res!V(raw.error);

    auto back = Conv.from(raw.value);
    static if (isExpectedLike!(typeof(back)))
    {
        if (back.hasError)
            return Res!V(back.error);
        return resOk(back.value);
    }
    else
        return resOk(back);
}

private Res!JSONValue encodeAA(T)(const T value)
if (is(T == V[K], V, K))
{
    alias V = typeof(T.init.values[0]);
    JSONValue[string] obj;
    foreach (k, ref v; value)
    {
        auto rv = encodeImpl(v);
        if (rv.error !is null)
            return rv;
        obj[aaKeyText(k)] = rv.value;
    }
    return resOk(JSONValue(obj));
}

private Res!T decodeAA(T)(JSONValue json)
if (is(T == V[K], V, K))
{
    alias V = typeof(T.init.values[0]);
    alias K = typeof(T.init.keys[0]);

    if (json.type != JSONType.object)
        return resFail!T("Cannot decode " ~ T.stringof ~ " at $: expected a JSON object");

    T result;
    foreach (keyStr, jval; json.object)
    {
        auto k = aaKeyParse!K(keyStr);
        if (k.error !is null)
            return Res!T(k.error);
        auto rv = decodeImpl!V(jval);
        if (rv.error !is null)
            return Res!T(rv.error);
        result[k.value] = rv.value;
    }
    return resOk(result);
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
            alias names = wireNames!(Json, K, resolveCaseStyle!(Json, K));
            static foreach (i, m; __traits(allMembers, K))
                if (k == __traits(getMember, K, m))
                    return names[i];
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
private Res!K aaKeyParse(K)(string keyStr)
{
    static if (is(K == string))
        return resOk(keyStr);
    else static if (is(K == enum))
    {
        enum repr = resolveRepr!(Json, K);
        static if (repr == Repr.name)
        {
            enum style = resolveCaseStyle!(Json, K);
            alias names = wireNames!(Json, K, style);
            static foreach (i, m; __traits(allMembers, K))
                if (keyStr == names[i])
                    return resOk(__traits(getMember, K, m));
            return resFail!K(
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
                    return resFail!K("Cannot decode " ~ K.stringof ~ " key \"" ~ keyStr ~ "\": " ~ e.msg);
            }
            auto member = enumFromValue!K(orig);
            if (member.hasError)
                return resFail!K("Cannot decode " ~ K.stringof ~ " key \"" ~ keyStr ~ "\": " ~ member.error.context);
            return resOk(member.value);
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
        foreach (i, n; wireNames!(Json, E, style))
        {
            if (i)
                s ~= ", ";
            s ~= n;
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

    // JSONValue passes through unchanged in both directions.
    auto raw = JSONValue(["k": JSONValue(1)]);
    assert(toJSON(raw).value == raw);
    assert(fromJSON!JSONValue(raw).value == raw);
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

@("wired.json.wireOptional")
@system unittest
{
    static struct S
    {
        @WireOptional() Nullable!int a;             // whenEmpty: omit when empty
        @WireOptional(WireSkip.whenDefault) int b;  // omit at declared default
        @WireOptional(WireSkip.never) Nullable!int c;
    }

    // Encode omission.
    auto j = toJSON(S(Nullable!int.init, 0, Nullable!int.init)).value;
    assert("a" !in j.object);        // empty Nullable omitted
    assert("b" !in j.object);        // int 0 == default, omitted
    assert(j["c"].type == JSONType.null_); // never → emitted as null

    auto j2 = toJSON(S(Nullable!int(5), 7, Nullable!int.init)).value;
    assert(j2["a"] == JSONValue(5) && j2["b"] == JSONValue(7));

    // Decode: missing optional fields fall back to defaults.
    auto r = fromJSON!S(parseObject(`{}`));
    assert(r.value.a.isNull && r.value.b == 0 && r.value.c.isNull);

    // onInvalid: a present but invalid value falls back to the default.
    static struct T
    {
        @WireOptional(onInvalid: WireInvalid.useDefault) int x;
    }
    auto ri = fromJSON!T(parseObject(`{"x":"not-a-number"}`));
    assert(ri.hasValue && ri.value.x == 0);

    // Without useDefault (default reject), the same input is an error.
    static struct T2 { @WireOptional() int x; }
    assert(fromJSON!T2(parseObject(`{"x":"nope"}`)).hasError);
}

@("wired.json.optional")
@system unittest
{
    import optional : no, some, Optional;

    assert(toJSON(no!int).value == JSONValue(null));
    assert(toJSON(some(7)).value == JSONValue(7));
    assert(fromJSON!(Optional!int)(JSONValue(null)).value.empty);
    assert(fromJSON!(Optional!int)(JSONValue(7)).value.front == 7);

    // A missing Optional field decodes to empty (none).
    static struct S { int a; Optional!int b; }
    auto r = fromJSON!S(parseObject(`{"a":1}`));
    assert(r.value.a == 1 && r.value.b.empty);
}

@("wired.json.fileHelpers")
@system unittest
{
    import std.file : exists, remove, readText, tempDir;
    import std.path : buildPath;

    static struct Cfg { string host; int port; }

    const path = buildPath(tempDir, "wired-test-cfg.json");
    scope(exit) if (path.exists) remove(path);

    assert(!writeJSONFile(Cfg("localhost", 8080), path).hasError);
    assert(readText(path)[$ - 1] == '\n'); // trailing newline

    auto r = readJSONFile!Cfg(path);
    assert(r.hasValue && r.value == Cfg("localhost", 8080));

    // Missing file → read-stage error.
    assert(readJSONFile!Cfg(buildPath(tempDir, "wired-does-not-exist.json")).hasError);
}

version (unittest) private JSONValue parseObject(string s)
{
    return parseJSON(s);
}
