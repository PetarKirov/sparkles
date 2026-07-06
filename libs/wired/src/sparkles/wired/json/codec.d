/**
JSON codec for `sparkles:wired`.

Defines the `Json` format marker and the `Expected`-based encode/decode
surface (`toJSON` / `fromJSON` / `writeJSON`), driving enum, aggregate, and
container handling through the `sparkles.wired.policy` resolvers under the
`Json` tag. Encoding and decoding never throw — a failure is captured as
the `JsonError` payload of the returned `Expected`
(`docs/specs/wired/SPEC.md` §9, §11.6).

The codec runs on the native arena engine (document model, reader, writer —
SPEC §11); `std.json.JSONValue` remains only as the owned generic-JSON
passthrough type (§4.2) and a one-release `fromJSON` compatibility shim.
*/
module sparkles.wired.json.codec;

import std.datetime.systime : SysTime;
import std.json : JSONType, JSONValue;
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

/// Alias for the encode/decode result: a value or a `JsonError` describing
/// the failure — the backend never throws (§9, §11.6).
alias JsonResult(T) = Expected!(T, JsonError);

/// The text type `toJSON` returns: small documents stay in the inline
/// buffer, larger ones spill to `pureMalloc` — no GC either way.
alias JsonString = SmallBuffer!(char, 256);

// ─────────────────────────────────────────────────────────────────────────────
// Encoding
// ─────────────────────────────────────────────────────────────────────────────

/// Encodes `value` as minified JSON text under the `Json` format, without
/// throwing (§11.6). The writer-based $(LREF writeJSON) is the primary
/// form; this convenience wrapper renders into a $(LREF JsonString).
Expected!(JsonString, JsonError) toJSON(T)(const T value)
{
    JsonString buf;
    auto r = encodeNative!(JsonWriteOptions.init)(value, buf, 0);
    if (r.failed)
        return err!JsonString(r.error);
    return ok!JsonError(buf);
}

// ─────────────────────────────────────────────────────────────────────────────
// File helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Reads UTF-8 from `path`, parses it with the native engine, and decodes
/// it into a `T` — without throwing (§4.1). The error identifies the
/// failing stage: I/O failures are `fileRead`-stage errors; parse and
/// decode failures keep their stage and path, with the file recorded for
/// the rendered message.
Expected!(T, JsonError) readJSONFile(T)(string path)
{
    import std.file : readText;

    string text;
    try
        text = readText(path);
    catch (Exception e)
    {
        JsonError fe;
        fe.stage = JsonStage.fileRead;
        fe.filePath ~= path;
        fe.reason = e.msg;
        return err!T(fe);
    }

    auto r = fromJSON!T(text);
    if (r.hasError)
    {
        auto fe = r.error;
        fe.filePath ~= path;
        return err!T(fe);
    }
    return r;
}

/// Encodes `value` and writes it to `path` atomically (temp file in the
/// same directory + rename) with a trailing newline, creating missing
/// parent directories — without throwing (§4.1). `compact` selects
/// single-line vs pretty rendering (SPEC §11.4: 2-space indent, `": "`,
/// LF).
Expected!(void, JsonError) writeJSONFile(T)(const T value, string path,
    bool compact = false)
{
    import std.array : appender;
    import std.file : mkdirRecurse, rename, write;
    import std.path : dirName;

    auto buf = appender!string;
    auto enc = compact
        ? writeJSON!(JsonWriteOptions.init)(value, buf)
        : writeJSON!(JsonWriteOptions(pretty: true))(value, buf);
    if (enc.hasError)
    {
        auto fe = enc.error;
        fe.filePath ~= path;
        return err!void(fe);
    }
    buf ~= '\n';

    JsonError ioError(string reason)
    {
        JsonError fe;
        fe.stage = JsonStage.fileWrite;
        fe.filePath ~= path;
        fe.reason = reason;
        return fe;
    }

    const dir = path.dirName;
    try
    {
        if (dir.length && dir != ".")
            mkdirRecurse(dir);
    }
    catch (Exception e)
        return err!void(ioError(e.msg));

    const tmp = path ~ ".wired-tmp";
    try
    {
        write(tmp, buf[]);
        rename(tmp, path);
    }
    catch (Exception e)
        return err!void(ioError(e.msg));

    return ok!JsonError();
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

/// Decodes a `JSONValue` into a `T` — the one-release compatibility shim
/// (§11.6): the value is rendered to text and decoded by the native
/// engine, so behavior matches `fromJSON!T(text)` exactly.
Expected!(T, JsonError) fromJSON(T)(JSONValue json)
{
    import std.json : JSONOptions;

    string text;
    try
        text = json.toString(JSONOptions.doNotEscapeSlashes);
    catch (Exception e)
    {
        JsonError fe;
        fe.stage = JsonStage.encode;
        fe.targetType = "JSONValue";
        fe.reason = "value is not representable as JSON text";
        return err!T(fe);
    }
    return fromJSON!T(text);
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

// ─────────────────────────────────────────────────────────────────────────────
// Native engine surface (SPEC §11.6 stage 1 — additive)
// ─────────────────────────────────────────────────────────────────────────────
//
// The `JsonError`-native walks over the arena engine's borrowed views.
// The Exception/JSONValue surface above remains until the switch-over
// milestone; consumers instantiate only what they call. The walk keeps
// the same compile-time posture as the old one: a flat result channel
// (no per-node `Expected`), inline per-field dispatch, and the one-pass
// `fieldPolicies` table.

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.wired.json.document : JsonKind, JsonValue;
import sparkles.wired.json.error : JsonError, JsonStage, kindText,
    parseStageError;
import sparkles.wired.json.reader : parseJsonDocument;
import sparkles.wired.json.writer : JsonWriteOptions, newlineIndent,
    writeJsonString;

/// Decodes JSON text straight into a `T` — parse (arena engine) + native
/// view walk, no intermediate `JSONValue`. The `JsonError` renders the
/// SPEC §9 contract (parse-stage failures carry line/column).
Expected!(T, JsonError) fromJSON(T)(scope const(char)[] text)
{
    auto parsed = parseJsonDocument(text);
    if (parsed.hasError)
        return err!T(parseStageError(parsed.error, text));
    auto r = decodeNative!T(parsed.document.root);
    if (r.failed)
        return err!T(r.error);
    return ok!JsonError(r.value);
}

/// Decodes one parsed subtree (a borrowed view) into a `T`.
Expected!(T, JsonError) fromJSON(T)(scope JsonValue view)
{
    auto r = decodeNative!T(view);
    if (r.failed)
        return err!T(r.error);
    return ok!JsonError(r.value);
}

/// Streams `value` as JSON into any output range — the primary encode
/// API (SPEC §11.6): no intermediate document, no GC on the success path
/// beyond what `T`'s own iteration requires. `opts` selects minified
/// (default) or pretty rendering at compile time.
Expected!(void, JsonError) writeJSON(JsonWriteOptions opts = JsonWriteOptions.init,
    T, Writer)(const T value, ref Writer w)
{
    auto r = encodeNative!opts(value, w, 0);
    if (r.failed)
        return err!void(r.error);
    return ok!JsonError();
}

/// Internal walk result on the native channel: flat struct, no
/// per-node `Expected` instantiations (the `Res` lesson above).
private struct NRes(T)
{
    bool failed;
    JsonError error;
    static if (!is(T == void))
        T value;
}

private NRes!T nOk(T)(T value) => NRes!T(false, JsonError.init, value);

private NRes!T nFail(T)(JsonError e) => NRes!T(true, e);

/// Builds a leaf decode error: target/kind/reason (+ a compact value
/// summary when the view is a scalar).
private JsonError decodeError(T)(scope JsonValue v, string reason)
{
    JsonError e;
    e.stage = JsonStage.decode;
    e.targetType = T.stringof;
    e.reason = reason;
    e.actualKind = v.kind;
    summarizeInto(v, e);
    return e;
}

/// Fills `e.valueSummary` with a short rendering of a scalar view.
private void summarizeInto(scope JsonValue v, ref JsonError e) @safe pure nothrow @nogc
{
    import sparkles.base.text.float_conv : formatShortestDouble;
    import sparkles.base.text.writers : writeInteger;

    final switch (v.kind) with (JsonKind)
    {
    case string_:
        {
            const s = v.str;
            e.valueSummary ~= '"';
            const cut = s.length > 20 ? 20 : s.length;
            foreach (c; s[0 .. cut])
                e.valueSummary ~= (c < 0x20 ? ' ' : c);
            if (cut < s.length)
                e.valueSummary ~= "…";
            e.valueSummary ~= '"';
            break;
        }
    case integer:
        writeInteger(e.valueSummary, v.integer);
        break;
    case uinteger:
        writeInteger(e.valueSummary, v.uinteger);
        break;
    case floating:
        {
            char[40] buf = void;
            const len = formatShortestDouble(buf[], v.floating);
            e.valueSummary ~= buf[0 .. len];
            break;
        }
    case rawNumber:
        {
            const s = v.raw;
            const cut = s.length > 24 ? 24 : s.length;
            e.valueSummary ~= s[0 .. cut];
            break;
        }
    case none, null_, bool_, array, object:
        break; // kind name alone is enough
    }
}

/// The recursive native decode walk (mirrors `decodeImpl` over views).
private NRes!T decodeNative(T)(scope JsonValue v)
{
    alias U = Unqual!T;

    static if (is(U == JSONValue))
        return nOk(toStdJson(v)); // §4.2 passthrough: materialize the subtree

    else static if (hasConvert!(Json, U))
        return decodeViaNative!(convertOf!(Json, U), U)(v);

    else static if (is(U == bool))
    {
        if (v.kind != JsonKind.bool_)
            return nFail!T(decodeError!T(v, "expected a JSON boolean"));
        return nOk(v.boolean);
    }

    else static if (is(U == string))
    {
        if (v.kind != JsonKind.string_)
            return nFail!T(decodeError!T(v, "expected a JSON string"));
        return nOk(v.str.idup); // borrowed view → owned string
    }

    else static if (is(U == enum))
        return decodeEnumNative!(U, resolveRepr!(Json, U), resolveCaseStyle!(Json, U))(v);

    else static if (isIntegral!U)
        return decodeIntegralNative!T(v);

    else static if (isFloatingPoint!U)
    {
        switch (v.kind) with (JsonKind)
        {
        case floating:
            return nOk(cast(T) v.floating);
        case integer:
            return nOk(cast(T) v.integer);
        case uinteger:
            return nOk(cast(T) v.uinteger);
        default:
            return nFail!T(decodeError!T(v, "expected a JSON number"));
        }
    }

    else static if (is(U == E[], E))
    {
        static if (isSomeChar!E)
        {
            if (v.kind != JsonKind.string_)
                return nFail!T(decodeError!T(v, "expected a JSON string"));
            import std.conv : to;

            try
                return nOk(v.str.to!U);
            catch (Exception)
                return nFail!T(decodeError!T(v, "string does not fit the character type"));
        }
        else
        {
            if (v.kind != JsonKind.array)
                return nFail!T(decodeError!T(v, "expected a JSON array"));
            U result;
            result.reserve(v.length);
            size_t idx;
            foreach (elem; v.byElement)
            {
                auto r = decodeNative!E(elem);
                if (r.failed)
                {
                    r.error.prependIndex(idx);
                    return nFail!T(r.error);
                }
                result ~= r.value;
                idx++;
            }
            return nOk(result);
        }
    }

    else static if (is(U == V[K], V, K))
        return decodeAANative!U(v);

    else static if (is(U == Nullable!N, N))
    {
        if (v.kind == JsonKind.null_)
            return nOk(U.init);
        auto r = decodeNative!N(v);
        if (r.failed)
            return nFail!T(r.error);
        return nOk(U(r.value));
    }

    else static if (is(U == Optional!N, N))
    {
        if (v.kind == JsonKind.null_)
            return nOk(U.init);
        auto r = decodeNative!N(v);
        if (r.failed)
            return nFail!T(r.error);
        return nOk(some(r.value));
    }

    else static if (is(U == Ternary))
    {
        switch (v.kind) with (JsonKind)
        {
        case null_:
            return nOk(Ternary.unknown);
        case bool_:
            return nOk(v.boolean ? Ternary.yes : Ternary.no);
        default:
            return nFail!T(decodeError!T(v, "expected null, true, or false"));
        }
    }

    else static if (is(U == SysTime))
    {
        if (v.kind != JsonKind.string_)
            return nFail!T(decodeError!T(v, "expected a JSON string"));
        const s = v.str;
        if (!hasZoneOffset(cast(string) s))
            return nFail!T(decodeError!T(v,
                "timestamp must include an explicit UTC marker or offset"));
        try
            return nOk(SysTime.fromISOExtString(s).toUTC);
        catch (Exception e)
            return nFail!T(decodeError!T(v, "not an ISO-8601 extended timestamp"));
    }

    else static if (isSumType!U)
        return decodeSumTypeNative!(U, MatchStrategy.exactlyOne)(v);

    else static if (is(U == struct))
        return decodeStructNative!T(v);

    else
        static assert(false, "wired: unsupported type for fromJSON: " ~ T.stringof);
}

private NRes!T decodeIntegralNative(T)(scope JsonValue v)
{
    // The reader classifies exactly: integer fits long, uinteger only ulong.
    if (v.kind == JsonKind.integer)
    {
        const x = v.integer;
        static if (__traits(isUnsigned, T))
        {
            if (x < 0 || x > T.max)
                return nFail!T(decodeError!T(v, "value out of range"));
        }
        else
        {
            if (x < T.min || x > T.max)
                return nFail!T(decodeError!T(v, "value out of range"));
        }
        return nOk(cast(T) x);
    }
    if (v.kind == JsonKind.uinteger)
    {
        const x = v.uinteger;
        if (x > T.max)
            return nFail!T(decodeError!T(v, "value out of range"));
        return nOk(cast(T) x);
    }
    return nFail!T(decodeError!T(v, "expected an integer"));
}

private NRes!E decodeEnumNative(E, Repr repr, CaseStyle style)(scope JsonValue v)
if (is(E == enum))
{
    static if (repr == Repr.value)
    {
        auto orig = decodeNative!(OriginalType!E)(v);
        if (orig.failed)
        {
            orig.error.targetType = E.stringof;
            return nFail!E(orig.error);
        }
        auto member = enumFromValue!E(orig.value);
        if (member.hasError)
            return nFail!E(decodeError!E(v, member.error.context));
        return nOk(member.value);
    }
    else
    {
        if (v.kind != JsonKind.string_)
            return nFail!E(decodeError!E(v, "expected a JSON string"));

        alias names = wireNames!(Json, E, style);
        static foreach (i, m; __traits(allMembers, E))
            if (v.str == names[i])
                return nOk(__traits(getMember, E, m));

        return nFail!E(decodeError!E(v, "expected one of: " ~ nameList!(E, style)));
    }
}

/// Single-pass struct decode: one `byKeyValue` walk with a compile-time
/// string switch over the resolved field keys and a seen-mask for the
/// required-field check — unknown keys hop over their extent for free
/// (the old walk did one object lookup per field instead).
private NRes!T decodeStructNative(T)(scope JsonValue v)
if (is(T == struct))
{
    if (v.kind != JsonKind.object)
        return nFail!T(decodeError!T(v, "expected a JSON object"));

    alias policies = fieldPolicies!(Json, T);
    T result;
    bool[policies.length > 0 ? policies.length : 1] seen;

    foreach (m; v.byKeyValue)
    {
        sw: switch (m.key)
        {
            static foreach (i; 0 .. policies.length)
            {
        case policies[i].key:
                {
                    alias V = typeof(T.tupleof[i]);

                    static if (policies[i].hasConvert)
                        auto r = decodeViaNative!(convertOf!(Json, T.tupleof[i]), V)(m.value);
                    else static if (is(V == enum))
                        auto r = decodeEnumNative!(V,
                            policies[i].reprFor(WireTarget.all, resolveRepr!(Json, V)),
                            policies[i].caseFor(WireTarget.all, resolveCaseStyle!(Json, V)))(
                            m.value);
                    else static if (is(V == E[], E) && is(E == enum))
                        auto r = decodeEnumArrayNative!(E,
                            policies[i].reprFor(WireTarget.value, resolveRepr!(Json, E)),
                            policies[i].caseFor(WireTarget.value, resolveCaseStyle!(Json, E)))(
                            m.value);
                    else static if (isSumType!V)
                        auto r = decodeSumTypeNative!(V, policies[i].match)(m.value);
                    else
                        auto r = decodeNative!V(m.value);

                    if (r.failed)
                    {
                        // Present but invalid under `useDefault` keeps the
                        // default (§5.4); otherwise propagate with the path.
                        static if (!(policies[i].optional
                                && policies[i].onInvalid == WireInvalid.useDefault))
                        {
                            r.error.prependKey(policies[i].key);
                            return nFail!T(r.error);
                        }
                    }
                    else
                        result.tupleof[i] = r.value;
                    seen[i] = true;
                    break sw;
                }
            }
        default:
            break; // unknown key: skipped (extent hop)
        }
    }

    static foreach (i; 0 .. policies.length)
    {{
        alias V = typeof(T.tupleof[i]);
        static if (!(isNullAware!V || policies[i].optional))
        {
            if (!seen[i])
            {
                JsonError e;
                e.stage = JsonStage.decode;
                e.targetType = T.stringof;
                e.reason = "missing required field";
                e.prependKey(policies[i].key);
                return nFail!T(e);
            }
        }
    }}
    return nOk(result);
}

private NRes!(E[]) decodeEnumArrayNative(E, Repr repr, CaseStyle style)(scope JsonValue v)
if (is(E == enum))
{
    if (v.kind != JsonKind.array)
        return nFail!(E[])(decodeError!(E[])(v, "expected a JSON array"));
    E[] result;
    result.reserve(v.length);
    size_t idx;
    foreach (elem; v.byElement)
    {
        auto r = decodeEnumNative!(E, repr, style)(elem);
        if (r.failed)
        {
            r.error.prependIndex(idx);
            return nFail!(E[])(r.error);
        }
        result ~= r.value;
        idx++;
    }
    return nOk(result);
}

private NRes!ST decodeSumTypeNative(ST, MatchStrategy strat)(scope JsonValue v)
if (isSumType!ST)
{
    alias Types = TemplateArgsOf!ST;

    static if (strat == MatchStrategy.first)
    {
        static foreach (V; Types)
        {{
            auto r = decodeNative!V(v);
            if (!r.failed)
                return nOk(ST(r.value));
        }}
        return nFail!ST(decodeError!ST(v, "no variant matched"));
    }
    else
    {
        ST result;
        size_t matches = 0;
        static foreach (V; Types)
        {{
            auto r = decodeNative!V(v);
            if (!r.failed)
            {
                matches++;
                // Fresh local, no self-reference: SumType.opAssign's
                // @system-ness guards against aliasing the overwritten
                // alternative, which cannot happen here.
                () @trusted { result = ST(r.value); }();
            }
        }}
        if (matches == 1)
            return nOk(result);
        return nFail!ST(decodeError!ST(v, matches == 0
                ? "no variant matched" : "ambiguous — multiple variants matched"));
    }
}

private NRes!V decodeViaNative(alias Conv, V)(scope JsonValue v)
{
    static assert(!is(Conv.from == void),
        "wired: a serialize-only @WireConvert cannot decode " ~ V.stringof);

    alias Raw = typeof(Conv.to(V.init));
    static if (isExpectedLike!Raw)
        alias WireT = typeof(Raw.init.value);
    else
        alias WireT = Raw;

    auto raw = decodeNative!WireT(v);
    if (raw.failed)
    {
        raw.error.targetType = V.stringof;
        return nFail!V(raw.error);
    }

    auto back = Conv.from(raw.value);
    static if (isExpectedLike!(typeof(back)))
    {
        if (back.hasError)
            return nFail!V(decodeError!V(v, back.error.msg));
        return nOk(back.value);
    }
    else
        return nOk(back);
}

private NRes!T decodeAANative(T)(scope JsonValue v)
if (is(T == V[K], V, K))
{
    alias V = typeof(T.init.values[0]);
    alias K = typeof(T.init.keys[0]);

    if (v.kind != JsonKind.object)
        return nFail!T(decodeError!T(v, "expected a JSON object"));

    T result;
    foreach (m; v.byKeyValue)
    {
        auto k = aaKeyParseNative!K(m.key);
        if (k.failed)
            return nFail!T(k.error);
        auto rv = decodeNative!V(m.value);
        if (rv.failed)
        {
            rv.error.prependKey(m.key);
            return nFail!T(rv.error);
        }
        result[k.value] = rv.value;
    }
    return nOk(result);
}

private NRes!K aaKeyParseNative(K)(scope const(char)[] keyStr)
{
    static if (is(K == string))
        return nOk(keyStr.idup);
    else static if (is(K == enum))
    {
        enum repr = resolveRepr!(Json, K);
        static if (repr == Repr.name)
        {
            enum style = resolveCaseStyle!(Json, K);
            alias names = wireNames!(Json, K, style);
            static foreach (i, m; __traits(allMembers, K))
                if (keyStr == names[i])
                    return nOk(__traits(getMember, K, m));
            JsonError e;
            e.stage = JsonStage.decode;
            e.targetType = K.stringof;
            e.reason = "expected one of: " ~ nameList!(K, style);
            e.prependKey(keyStr);
            return nFail!K(e);
        }
        else
        {
            import std.conv : to, ConvException;

            OriginalType!K orig;
            static if (is(OriginalType!K == string))
                orig = keyStr.idup;
            else
            {
                try
                    orig = keyStr.to!(OriginalType!K);
                catch (ConvException)
                {
                    JsonError e;
                    e.stage = JsonStage.decode;
                    e.targetType = K.stringof;
                    e.reason = "key is not a value of the enum's underlying type";
                    e.prependKey(keyStr);
                    return nFail!K(e);
                }
            }
            auto member = enumFromValue!K(orig);
            if (member.hasError)
            {
                JsonError e;
                e.stage = JsonStage.decode;
                e.targetType = K.stringof;
                e.reason = member.error.context;
                e.prependKey(keyStr);
                return nFail!K(e);
            }
            return nOk(member.value);
        }
    }
    else
        static assert(false,
            "wired: associative-array keys must be string or enum, not " ~ K.stringof);
}

/// Materializes a parsed subtree as a `std.json.JSONValue` — the §4.2
/// passthrough escape hatch under the native engine. `@trusted`: the
/// tree building is plainly memory-safe; `std.json`'s construction and
/// assignment operators simply lack `@safe` annotations.
private JSONValue toStdJson(scope JsonValue v) @trusted
{
    final switch (v.kind) with (JsonKind)
    {
    case null_:
        return JSONValue(null);
    case bool_:
        return JSONValue(v.boolean);
    case integer:
        return JSONValue(v.integer);
    case uinteger:
        return JSONValue(v.uinteger);
    case floating:
        return JSONValue(v.floating);
    case string_:
        return JSONValue(v.str.idup);
    case rawNumber:
        return JSONValue(v.raw.idup); // raw token as text (lossless)
    case array:
        {
            JSONValue[] arr;
            arr.reserve(v.length);
            foreach (e; v.byElement)
                arr ~= toStdJson(e);
            return JSONValue(arr);
        }
    case object:
        {
            JSONValue[string] obj;
            foreach (m; v.byKeyValue)
                obj[m.key.idup] = toStdJson(m.value);
            return JSONValue(obj);
        }
    case none:
        assert(false, "cannot materialize an invalid view");
    }
}

// ── native encode (streaming, writer-based) ──────────────────────────────────

private alias EncRes = NRes!void;

private EncRes encOk() @safe pure nothrow @nogc => EncRes(false);

private JsonError encodeError(T)(string reason)
{
    JsonError e;
    e.stage = JsonStage.encode;
    e.targetType = T.stringof;
    e.reason = reason;
    return e;
}

/// The recursive native encode walk (mirrors `encodeImpl`, but streams
/// tokens instead of building a tree).
private EncRes encodeNative(JsonWriteOptions opts, T, Writer)(
    const T value, ref Writer w, uint depth)
{
    import std.range.primitives : put;

    alias U = Unqual!T;

    static if (is(U == JSONValue))
        return writeStdJson!opts(value, w, depth);

    else static if (hasConvert!(Json, U))
        return encodeViaNative!(convertOf!(Json, U), U, opts)(value, w, depth);

    else static if (is(U == bool))
    {
        put(w, value ? "true" : "false");
        return encOk();
    }

    else static if (is(U == string))
    {
        writeJsonString(w, value);
        return encOk();
    }

    else static if (is(U == enum))
        return encodeEnumNative!(U, resolveRepr!(Json, U),
            resolveCaseStyle!(Json, U))(value, w);


    else static if (isIntegral!U)
    {
        import sparkles.base.text.writers : writeInteger;

        writeInteger(w, value);
        return encOk();
    }

    else static if (isFloatingPoint!U)
    {
        import std.math : isFinite;
        import sparkles.base.text.float_conv : formatShortestDouble;

        if (!isFinite(value))
            return EncRes(true,
                encodeError!T("NaN and infinity are not representable in JSON"));
        char[40] buf = void;
        const len = formatShortestDouble(buf[], value);
        put(w, buf[0 .. len]);
        return encOk();
    }

    else static if (is(U == E[], E))
    {
        static if (isSomeChar!E)
        {
            import std.conv : to;

            static if (is(E == char))
                writeJsonString(w, value);
            else
                writeJsonString(w, value.to!string);
            return encOk();
        }
        else
        {
            if (value.length == 0)
            {
                put(w, "[]");
                return encOk();
            }
            put(w, '[');
            foreach (i, ref e; value)
            {
                if (i)
                    put(w, ',');
                static if (opts.pretty)
                    newlineIndent(w, depth + 1);
                auto r = encodeNative!opts(e, w, depth + 1);
                if (r.failed)
                {
                    r.error.prependIndex(i);
                    return r;
                }
            }
            static if (opts.pretty)
                newlineIndent(w, depth);
            put(w, ']');
            return encOk();
        }
    }

    else static if (is(U == V[K], V, K))
        return encodeAANative!opts(value, w, depth);

    else static if (is(U == Nullable!N, N))
    {
        if (value.isNull)
        {
            put(w, "null");
            return encOk();
        }
        return encodeNative!opts(value.get, w, depth);
    }

    else static if (is(U == Optional!N, N))
    {
        if (value.empty)
        {
            put(w, "null");
            return encOk();
        }
        return encodeNative!opts(value.front, w, depth);
    }

    else static if (is(U == Ternary))
    {
        put(w, value == Ternary.unknown ? "null"
                : value == Ternary.yes ? "true" : "false");
        return encOk();
    }

    else static if (is(U == SysTime))
    {
        writeJsonString(w, value.toUTC.toISOExtString);
        return encOk();
    }

    else static if (isSumType!U)
        return value.match!(v => encodeNative!opts(v, w, depth));

    else static if (is(U == struct))
        return encodeStructNative!opts(value, w, depth);

    else
        static assert(false, "wired: unsupported type for writeJSON: " ~ T.stringof);
}

private EncRes encodeEnumNative(E, Repr repr, CaseStyle style, Writer)(
    const E value, ref Writer w)
if (is(E == enum))
{
    static if (repr == Repr.value)
        // Scalar payload: depth and pretty layout cannot apply.
        return encodeNative!(JsonWriteOptions.init)(
            cast(OriginalType!E) value, w, 0);
    else
    {
        alias names = wireNames!(Json, E, style);
        static foreach (i, m; __traits(allMembers, E))
            if (value == __traits(getMember, E, m))
            {
                writeJsonString(w, names[i]);
                return encOk();
            }
        return EncRes(true, encodeError!E("value is not a declared member"));
    }
}

/// Struct fields stream in declaration order (SPEC §11.6), skip policies
/// applied inline exactly as in the tree-building walk.
private EncRes encodeStructNative(JsonWriteOptions opts, T, Writer)(
    const T value, ref Writer w, uint depth)
if (is(T == struct))
{
    import std.range.primitives : put;

    alias policies = fieldPolicies!(Json, T);

    put(w, '{');
    bool first = true;
    static foreach (i; 0 .. policies.length)
    {{
        alias V = typeof(T.tupleof[i]);

        static if (policies[i].skip == WireSkip.never)
            enum bool omitted = false;
        else static if (policies[i].skip == WireSkip.whenDefault)
            const bool omitted = value.tupleof[i] == T.init.tupleof[i];
        else
            const bool omitted = isEmptyValue(value.tupleof[i]);

        if (!omitted)
        {
            if (!first)
                put(w, ',');
            first = false;
            static if (opts.pretty)
                newlineIndent(w, depth + 1);
            writeJsonString(w, policies[i].key);
            static if (opts.pretty)
                put(w, ": ");
            else
                put(w, ':');

            static if (policies[i].hasConvert)
                auto r = encodeViaNative!(convertOf!(Json, T.tupleof[i]), V, opts)(
                    value.tupleof[i], w, depth + 1);
            else static if (is(V == enum))
                auto r = encodeEnumNative!(V,
                    policies[i].reprFor(WireTarget.all, resolveRepr!(Json, V)),
                    policies[i].caseFor(WireTarget.all, resolveCaseStyle!(Json, V)))(
                    value.tupleof[i], w);
            else static if (is(V == E[], E) && is(E == enum))
                auto r = encodeEnumArrayNative!(E,
                    policies[i].reprFor(WireTarget.value, resolveRepr!(Json, E)),
                    policies[i].caseFor(WireTarget.value, resolveCaseStyle!(Json, E)))(
                    value.tupleof[i], w);
            else
                auto r = encodeNative!opts(value.tupleof[i], w, depth + 1);

            if (r.failed)
            {
                r.error.prependKey(policies[i].key);
                return r;
            }
        }
    }}
    static if (opts.pretty)
    {
        if (!first) // any member emitted
            newlineIndent(w, depth);
    }
    put(w, '}');
    return encOk();
}

private EncRes encodeEnumArrayNative(E, Repr repr, CaseStyle style, Writer)(
    const E[] values, ref Writer w)
if (is(E == enum))
{
    import std.range.primitives : put;

    put(w, '[');
    foreach (i, e; values)
    {
        if (i)
            put(w, ',');
        auto r = encodeEnumNative!(E, repr, style)(e, w);
        if (r.failed)
        {
            r.error.prependIndex(i);
            return r;
        }
    }
    put(w, ']');
    return encOk();
}

private EncRes encodeViaNative(alias Conv, V,
    JsonWriteOptions opts, Writer)(const V value, ref Writer w, uint depth)
{
    auto wire = Conv.to(value);
    static if (isExpectedLike!(typeof(wire)))
    {
        if (wire.hasError)
            return EncRes(true, encodeError!V(wire.error.msg));
        return encodeNative!opts(wire.value, w, depth);
    }
    else
        return encodeNative!opts(wire, w, depth);
}

/// Associative arrays stream with lexicographically sorted keys
/// (SPEC §11.6 — deterministic output independent of hash order).
private EncRes encodeAANative(JsonWriteOptions opts, T, Writer)(
    const T value, ref Writer w, uint depth)
if (is(T == V[K], V, K))
{
    import std.algorithm.sorting : sort;
    import std.range.primitives : put;

    alias K = typeof(T.init.keys[0]);

    static struct Pair
    {
        string text;
        K key;
    }

    Pair[] pairs;
    pairs.reserve(value.length);
    foreach (k, ref const _; value)
        pairs ~= Pair(aaKeyText(k), k);
    pairs.sort!((a, b) => a.text < b.text);

    if (pairs.length == 0)
    {
        put(w, "{}");
        return encOk();
    }
    put(w, '{');
    foreach (i, ref p; pairs)
    {
        if (i)
            put(w, ',');
        static if (opts.pretty)
            newlineIndent(w, depth + 1);
        writeJsonString(w, p.text);
        static if (opts.pretty)
            put(w, ": ");
        else
            put(w, ':');
        auto r = encodeNative!opts(value[p.key], w, depth + 1);
        if (r.failed)
        {
            r.error.prependKey(p.text);
            return r;
        }
    }
    static if (opts.pretty)
        newlineIndent(w, depth);
    put(w, '}');
    return encOk();
}

/// Streams a passed-through `JSONValue` (§4.2). Object keys sort; a NaN
/// or infinity inside is an encode error (resolves O3 strictly).
private EncRes writeStdJson(JsonWriteOptions opts, Writer)(
    const JSONValue v, ref Writer w, uint depth)
{
    import std.algorithm.sorting : sort;
    import std.math : isFinite;
    import std.range.primitives : put;
    import sparkles.base.text.float_conv : formatShortestDouble;
    import sparkles.base.text.writers : writeInteger;

    final switch (v.type)
    {
    case JSONType.null_:
        put(w, "null");
        return encOk();
    case JSONType.true_:
        put(w, "true");
        return encOk();
    case JSONType.false_:
        put(w, "false");
        return encOk();
    case JSONType.integer:
        writeInteger(w, v.integer);
        return encOk();
    case JSONType.uinteger:
        writeInteger(w, v.uinteger);
        return encOk();
    case JSONType.float_:
        {
            if (!isFinite(v.floating))
                return EncRes(true, encodeError!JSONValue(
                        "NaN and infinity are not representable in JSON"));
            char[40] buf = void;
            const len = formatShortestDouble(buf[], v.floating);
            put(w, buf[0 .. len]);
            return encOk();
        }
    case JSONType.string:
        writeJsonString(w, v.str);
        return encOk();
    case JSONType.array:
        {
            if (v.arrayNoRef.length == 0)
            {
                put(w, "[]");
                return encOk();
            }
            put(w, '[');
            foreach (i, ref const e; v.arrayNoRef)
            {
                if (i)
                    put(w, ',');
                static if (opts.pretty)
                    newlineIndent(w, depth + 1);
                auto r = writeStdJson!opts(e, w, depth + 1);
                if (r.failed)
                {
                    r.error.prependIndex(i);
                    return r;
                }
            }
            static if (opts.pretty)
                newlineIndent(w, depth);
            put(w, ']');
            return encOk();
        }
    case JSONType.object:
        {
            auto obj = v.objectNoRef;
            string[] keys;
            keys.reserve(obj.length);
            foreach (k, ref const _; obj)
                keys ~= k;
            keys.sort();
            if (keys.length == 0)
            {
                put(w, "{}");
                return encOk();
            }
            put(w, '{');
            foreach (i, k; keys)
            {
                if (i)
                    put(w, ',');
                static if (opts.pretty)
                    newlineIndent(w, depth + 1);
                writeJsonString(w, k);
                static if (opts.pretty)
                    put(w, ": ");
                else
                    put(w, ':');
                auto r = writeStdJson!opts(obj[k], w, depth + 1);
                if (r.failed)
                {
                    r.error.prependKey(k);
                    return r;
                }
            }
            static if (opts.pretty)
                newlineIndent(w, depth);
            put(w, '}');
            return encOk();
        }
    }
}

version (unittest)
{
    /// `toJSON` text for assertions (asserts the encode succeeded).
    private string jsonText(T)(const T value)
    {
        auto r = toJSON(value);
        assert(!r.hasError);
        return r.value[].idup;
    }
}

@("wired.json.scalars")
@safe unittest
{
    assert(jsonText(true) == "true");
    assert(jsonText("hi") == `"hi"`);
    assert(jsonText(42) == "42");
    assert(jsonText(3.5) == "3.5");

    assert(fromJSON!bool("true").value == true);
    assert(fromJSON!string(`"hi"`).value == "hi");
    assert(fromJSON!int("42").value == 42);
    assert(fromJSON!double("3.5").value == 3.5);

    assert(fromJSON!int(`"42"`).hasError);
    assert(fromJSON!ubyte("300").hasError);
    assert(fromJSON!bool("1").hasError);

    // JSONValue passes through in both directions (§4.2), object keys
    // rendered sorted.
    auto raw = JSONValue(["k": JSONValue(1)]);
    assert(jsonText(raw) == `{"k":1}`);
    assert(fromJSON!JSONValue(`{"k":1}`).value == raw);
    assert(fromJSON!JSONValue(raw).value == raw); // compat shim
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

    assert(jsonText(Mode.fastPath) == `"fast_path"`);
    assert(jsonText(Mode.slowPath) == `"turbo"`);
    assert(fromJSON!Mode(`"fast_path"`).value == Mode.fastPath);
    assert(fromJSON!Mode(`"turbo"`).value == Mode.slowPath);
    assert(fromJSON!Mode(`"nope"`).hasError);

    @WireRepr!Json(Repr.value)
    enum Priority { low = 1, high = 5 }

    assert(jsonText(Priority.high) == "5");
    assert(fromJSON!Priority("5").value == Priority.high);
    assert(fromJSON!Priority("2").hasError);
}

@("wired.json.arrays")
@safe unittest
{
    assert(jsonText([1, 2, 3]) == "[1,2,3]");
    assert(fromJSON!(int[])("[1,2,3]").value == [1, 2, 3]);
    assert(fromJSON!(int[])("4").hasError);

    enum Suit { spades, hearts }
    assert(jsonText([Suit.spades, Suit.hearts]) == `["spades","hearts"]`);
    assert(fromJSON!(Suit[])(`["hearts","spades"]`).value
        == [Suit.hearts, Suit.spades]);
}

@("wired.json.aggregate")
@safe unittest
{
    static struct Server
    {
        string host;
        ushort port;
    }

    auto s = Server("localhost", 8080);
    const text = jsonText(s); // fields in declaration order (§11.6)
    assert(text == `{"host":"localhost","port":8080}`);
    assert(fromJSON!Server(text).value == s);

    // Missing required field is a decode error naming the path.
    auto bad = fromJSON!Server(`{"host":"x"}`);
    assert(bad.hasError);
    assert(bad.error.path[] == ".port");
}

@("wired.json.aggregateFieldPolicy")
@safe unittest
{
    struct Toml {}

    @WireCase!Json(CaseStyle.snakeCase)
    static struct Config
    {
        @WireName!Json("db_host") string dbHost;
        int retryCount;
    }

    auto c = Config("h", 3);
    const text = jsonText(c);
    assert(text == `{"db_host":"h","retry_count":3}`); // WireName + recasing
    assert(fromJSON!Config(text).value == c);
}

@("wired.json.fieldEnumOverride")
@safe unittest
{
    enum Mode { fastPath, slowPath }

    static struct S
    {
        @WireCase!Json(CaseStyle.kebabCase) Mode m;
    }

    // The field-level WireCase overrides the (absent) type policy.
    assert(jsonText(S(Mode.fastPath)) == `{"m":"fast-path"}`);
    assert(fromJSON!S(jsonText(S(Mode.slowPath))).value == S(Mode.slowPath));
}

@("wired.json.nullableAndTernary")
@safe unittest
{
    assert(jsonText(Nullable!int.init) == "null");
    assert(jsonText(Nullable!int(7)) == "7");
    assert(fromJSON!(Nullable!int)("null").value.isNull);
    assert(fromJSON!(Nullable!int)("7").value.get == 7);

    assert(jsonText(Ternary.unknown) == "null");
    assert(jsonText(Ternary.yes) == "true");
    assert(fromJSON!Ternary("null").value == Ternary.unknown);
    assert(fromJSON!Ternary("false").value == Ternary.no);

    // A missing null-aware field decodes to its empty value.
    static struct S { int a; Nullable!int b; Ternary c; }
    auto r = fromJSON!S(`{"a":1}`);
    assert(r.value.a == 1 && r.value.b.isNull && r.value.c == Ternary.unknown);
}

@("wired.json.sysTime")
@system unittest
{
    auto t = SysTime.fromISOExtString("2026-07-01T12:30:00Z");
    const text = jsonText(t);
    assert(text == `"2026-07-01T12:30:00Z"`);
    assert(fromJSON!SysTime(text).value == t.toUTC);

    // Offsetless timestamps are rejected.
    assert(fromJSON!SysTime(`"2026-07-01T12:30:00"`).hasError);
}

@("wired.json.sumType")
@system unittest // -checkaction=context assert rendering of SumType is @system
{
    alias Cell = SumType!(int, string);

    assert(jsonText(Cell(42)) == "42");
    assert(jsonText(Cell("hi")) == `"hi"`);
    assert(fromJSON!Cell("42").value == Cell(42));
    assert(fromJSON!Cell(`"hi"`).value == Cell("hi"));

    // exactlyOne (default) rejects when no variant matches.
    assert(fromJSON!Cell("true").hasError);

    // Field-level @(WireMatch.first) picks the first matching arm.
    static struct Row
    {
        @(WireMatch.first!Json) SumType!(int, double) cell;
    }
    auto r = fromJSON!Row(`{"cell":42}`);
    assert(r.value.cell == SumType!(int, double)(42));
}

@("wired.json.associativeArrays")
@safe unittest
{
    // String-keyed AA — keys render sorted (§11.6).
    auto m = ["b": 2, "a": 1];
    assert(jsonText(m) == `{"a":1,"b":2}`);
    assert(fromJSON!(int[string])(jsonText(m)).value == m);

    // Enum-keyed AA by member name (default).
    enum Suit { spades, hearts }
    auto byName = [Suit.spades: 1, Suit.hearts: 2];
    assert(jsonText(byName) == `{"hearts":2,"spades":1}`);
    assert(fromJSON!(int[Suit])(jsonText(byName)).value == byName);

    // Enum-keyed AA by underlying value.
    @WireRepr!Json(Repr.value)
    enum Priority { low = 1, high = 5 }
    auto byVal = [Priority.low: "lo", Priority.high: "hi"];
    assert(jsonText(byVal) == `{"1":"lo","5":"hi"}`);
    assert(fromJSON!(string[Priority])(jsonText(byVal)).value == byVal);
}

@("wired.json.wireConvert")
@safe unittest
{
    import core.time : Duration, msecs;

    static struct Timer
    {
        @WireConvert!(d => d.total!"msecs", ms => msecs(ms))
        Duration timeout;
    }

    auto t = Timer(1500.msecs);
    const text = jsonText(t);
    assert(text == `{"timeout":1500}`); // Duration as its ms count
    assert(fromJSON!Timer(text).value == t);
}

@("wired.json.wireOptional")
@safe unittest
{
    static struct S
    {
        @WireOptional() Nullable!int a;             // whenEmpty: omit when empty
        @WireOptional(WireSkip.whenDefault) int b;  // omit at declared default
        @WireOptional(WireSkip.never) Nullable!int c;
    }

    // Encode omission.
    assert(jsonText(S(Nullable!int.init, 0, Nullable!int.init))
        == `{"c":null}`); // a and b omitted, c emitted as null
    assert(jsonText(S(Nullable!int(5), 7, Nullable!int.init))
        == `{"a":5,"b":7,"c":null}`);

    // Decode: missing optional fields fall back to defaults.
    auto r = fromJSON!S(`{}`);
    assert(r.value.a.isNull && r.value.b == 0 && r.value.c.isNull);

    // onInvalid: a present but invalid value falls back to the default.
    static struct T
    {
        @WireOptional(onInvalid: WireInvalid.useDefault) int x;
    }
    auto ri = fromJSON!T(`{"x":"not-a-number"}`);
    assert(ri.hasValue && ri.value.x == 0);

    // Without useDefault (default reject), the same input is an error.
    static struct T2 { @WireOptional() int x; }
    assert(fromJSON!T2(`{"x":"nope"}`).hasError);

    // whenDefault on an Optional field compares by emptiness and contents.
    static struct O
    {
        @WireOptional(WireSkip.whenDefault) Optional!string tag;
    }
    assert(jsonText(O.init) == "{}"); // empty == default → omitted
    assert(jsonText(O(some("x"))) == `{"tag":"x"}`);
}

@("wired.json.optional")
@safe unittest
{
    import optional : no, some, Optional;

    assert(jsonText(no!int) == "null");
    assert(jsonText(some(7)) == "7");
    assert(fromJSON!(Optional!int)("null").value.empty);
    assert(fromJSON!(Optional!int)("7").value.front == 7);

    // A missing Optional field decodes to empty (none).
    static struct S { int a; Optional!int b; }
    auto r = fromJSON!S(`{"a":1}`);
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
    const written = readText(path);
    assert(written == "{\n  \"host\": \"localhost\",\n  \"port\": 8080\n}\n");

    auto r = readJSONFile!Cfg(path);
    assert(r.hasValue && r.value == Cfg("localhost", 8080));

    // Compact form is single-line.
    assert(!writeJSONFile(Cfg("h", 1), path, true).hasError);
    assert(readText(path) == "{\"host\":\"h\",\"port\":1}\n");

    // Missing file → read-stage error naming the file.
    auto missing = readJSONFile!Cfg(buildPath(tempDir, "wired-does-not-exist.json"));
    assert(missing.hasError);
    assert(missing.error.stage == JsonStage.fileRead);
}

// ─────────────────────────────────────────────────────────────────────────────
// Native-surface tests (SPEC §11.6 stage 1)
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private enum NMode
    {
        off,
        fastPath,
        automatic,
    }

    private struct NServer
    {
        string host;
        ushort port;
        string[] tags;
        NMode mode;
        Nullable!int timeout;
        @WireOptional() int retries;
    }
}

@("wired.native.fromJSON.textRoundTrip")
@safe unittest
{
    import std.array : appender;

    const source = NServer("localhost", 8080, ["web", "edge"], NMode.fastPath,
        Nullable!int(30), 3);

    auto w = appender!string;
    assert(!writeJSON(source, w).hasError);
    assert(w[] == `{"host":"localhost","port":8080,"tags":["web","edge"],`
            ~ `"mode":"fastPath","timeout":30,"retries":3}`);

    auto back = fromJSON!NServer(w[]);
    assert(back.hasValue);
    assert(back.value == source);
}

@("wired.native.fromJSON.missingAndUnknownKeys")
@safe unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    // Unknown keys skip; missing null-aware/optional fields default.
    auto ok_ = fromJSON!NServer(
        `{"host":"h","port":1,"tags":[],"mode":"off","unknown":{"deep":[1,2]}}`);
    assert(ok_.hasValue);
    assert(ok_.value.timeout.isNull);
    assert(ok_.value.retries == 0);

    // Missing required field renders the SPEC §9 path.
    auto bad = fromJSON!NServer(`{"host":"h"}`);
    assert(bad.hasError);
    checkWriter!((ref b) => bad.error.toString(b))(
        "Cannot decode NServer at $.port: missing required field");
}

@("wired.native.fromJSON.nestedPathDiagnostics")
@safe unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    static struct Inner
    {
        ushort port;
    }

    static struct Outer
    {
        Inner server;
    }

    auto bad = fromJSON!Outer(`{"server": {"port": null}}`);
    assert(bad.hasError);
    checkWriter!((ref b) => bad.error.toString(b))(
        "Cannot decode ushort at $.server.port from JSON null: expected an integer");

    static struct List
    {
        int[] xs;
    }

    auto badIdx = fromJSON!List(`{"xs": [1, 2, "three"]}`);
    assert(badIdx.hasError);
    checkWriter!((ref b) => badIdx.error.toString(b))(
        `Cannot decode int at $.xs[2] from JSON string "three": expected an integer`);
}

@("wired.native.fromJSON.enumTokenDiagnostics")
@safe unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    auto bad = fromJSON!NMode(`"sideways"`);
    assert(bad.hasError);
    checkWriter!((ref b) => bad.error.toString(b))(
        `Cannot decode NMode at $ from JSON string "sideways": `
        ~ "expected one of: off, fastPath, automatic");
}

@("wired.native.fromJSON.parseStageLineColumn")
@safe unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    auto bad = fromJSON!int("{\n  \"a\": 01\n}");
    assert(bad.hasError);
    assert(bad.error.stage == JsonStage.parse);
    assert(bad.error.line == 2 && bad.error.column == 8);
}

@("wired.native.fromJSON.numbersAndWrappers")
@safe unittest
{
    assert(fromJSON!ulong(`18446744073709551615`).value == ulong.max);
    assert(fromJSON!byte(`-128`).value == byte.min);
    assert(fromJSON!byte(`128`).hasError); // out of range
    assert(fromJSON!double(`0.1`).value == 0.1);
    assert(fromJSON!(Nullable!int)(`null`).value.isNull);
    assert(fromJSON!(Optional!int)(`7`).value.front == 7);
    assert(fromJSON!Ternary(`null`).value == Ternary.unknown);
    assert(fromJSON!(int[string])(`{"b":2,"a":1}`).value == ["a": 1, "b": 2]);
    assert(fromJSON!(SumType!(int, string))(`"x"`).hasValue);
}

@("wired.native.fromJSON.viewSubtree")
@safe unittest
{
    import sparkles.wired.json.reader : parseJsonDocument;

    auto doc = parseJsonDocument(`{"config": {"port": 8080}}`);
    assert(doc.hasValue);

    static struct Config
    {
        ushort port;
    }

    auto sub = doc.document.root.objectGet("config");
    auto r = fromJSON!Config(sub);
    assert(r.hasValue);
    assert(r.value.port == 8080);
}

@("wired.native.writeJSON.policiesAndOrder")
@safe unittest
{
    import std.array : appender;
    import std.typecons : Ternary;

    // Declaration order (not sorted) + AA keys sorted + null-aware nulls.
    static struct Mixed
    {
        int[string] counts;
        Ternary flag;
        Optional!string note;
    }

    Mixed m;
    m.counts = ["zulu": 26, "alpha": 1];
    m.flag = Ternary.unknown;

    auto w = appender!string;
    assert(!writeJSON(m, w).hasError);
    assert(w[] == `{"counts":{"alpha":1,"zulu":26},"flag":null,"note":null}`);
}

@("wired.native.writeJSON.nanErrorWithPath")
@safe unittest
{
    import std.array : appender;
    import sparkles.base.smallbuffer : checkWriter;

    static struct Stats
    {
        double ratio;
    }

    auto w = appender!string;
    auto r = writeJSON(Stats(double.nan), w);
    assert(r.hasError);
    checkWriter!((ref b) => r.error.toString(b))(
        "Cannot encode double at $.ratio: "
        ~ "NaN and infinity are not representable in JSON");
}

@("wired.native.passthrough.jsonValueBothWays")
@safe unittest
{
    import std.array : appender;

    // §4.2: JSONValue decodes as the owned generic escape hatch and
    // streams back with sorted keys; NaN inside is an encode error (O3).
    auto sub = fromJSON!JSONValue(`{"z": 1, "a": [true, "x"]}`);
    assert(sub.hasValue);

    auto w = appender!string;
    assert(!writeJSON(sub.value, w).hasError);
    assert(w[] == `{"a":[true,"x"],"z":1}`);

    auto bad = appender!string;
    auto nanned = JSONValue(["k": JSONValue(double.nan)]);
    assert(writeJSON(nanned, bad).hasError);
}

@("wired.native.shimAgreesWithTextPath")
@system unittest // JSONValue construction via parseJSON is @system-adjacent
{
    // The same document through the JSONValue compat shim and the text
    // path must produce identical values.
    const text = `{"host":"h","port":80,"tags":["a"],"mode":"automatic",` ~
        `"timeout":null,"retries":9}`;
    import std.json : parseJSON;

    auto viaOld = parseJSON(text).fromJSON!NServer;
    auto viaNew = fromJSON!NServer(text);
    assert(viaOld.hasValue && viaNew.hasValue);
    assert(viaOld.value == viaNew.value);
}
