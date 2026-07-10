/++
The string↔typed JSON boundary: `std.json.parseJSON` throws on malformed input
and `sparkles:wired` reports decode errors as `Exception`s; these helpers fold
both into the tool's $(REF Result, result) channel so callers stay
exception-free (SPEC §10).
+/
module sparkles.release.json_utils;

import std.json : JSONValue, parseJSON, JSONException;

import sparkles.release.result : Result, success, failure;

// NOTE: no module-level `@safe:` — the wired decode/encode path infers
// `@system` for aggregates, and the templates below must stay free to infer.

/// `std.json.parseJSON` as a `Result`.
Result!JSONValue parseJsonText(string raw) @safe
{
    try
        return success(parseJSON(raw));
    catch (JSONException e)
        return failure!JSONValue("invalid JSON: " ~ e.msg);
}

/// Parses `raw` and decodes it into a `T` via `sparkles:wired`.
Result!T decodeJson(T)(string raw)
{
    import sparkles.wired : fromJSON;

    auto dom = parseJsonText(raw);
    if (dom.hasError)
        return failure!T(dom.error);
    auto decoded = fromJSON!T(dom.value);
    if (decoded.hasError)
        return failure!T(decoded.error.msg);
    return success(decoded.value);
}

/// Encodes `value` as a compact JSON string via `sparkles:wired`.
Result!string encodeJson(T)(in T value)
{
    import sparkles.wired : toJSON;

    auto encoded = toJSON(value);
    if (encoded.hasError)
        return failure!string(encoded.error.msg);
    return success(encoded.value.toString);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("json_utils.parseJsonText")
@safe unittest
{
    assert(parseJsonText(`{"a": 1}`).hasValue);
    auto bad = parseJsonText(`{"a": `);
    assert(bad.hasError);
}

@("json_utils.decodeJson.roundTrip")
@system unittest
{
    static struct Point
    {
        int x;
        int y;
    }

    auto p = decodeJson!Point(`{"x": 1, "y": 2, "extra": "ignored"}`);
    assert(p.hasValue);
    assert(p.value == Point(1, 2));

    assert(decodeJson!Point(`{"x": 1}`).hasError);       // missing field
    assert(decodeJson!Point(`not json`).hasError);

    assert(encodeJson(Point(1, 2)).value == `{"x":1,"y":2}`);
}
