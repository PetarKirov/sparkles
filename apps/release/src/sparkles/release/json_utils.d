/++
The string↔typed JSON boundary: `std.json.parseJSON` throws on malformed input
and `sparkles:wired` reports decode/encode failures as a structured
`JsonError`; these helpers fold both into the tool's $(REF Result, result)
channel so callers stay exception-free (SPEC §10).
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
    auto dom = parseJsonText(raw);
    if (dom.hasError)
        return failure!T(dom.error);
    return decodeJsonValue!T(dom.value);
}

/// Decodes an already-parsed DOM into a `T` — for callers that must inspect or
/// normalize the JSON before it meets the typed model.
Result!T decodeJsonValue(T)(in JSONValue dom)
{
    import sparkles.wired : fromJSON;

    auto decoded = fromJSON!T(dom);
    if (decoded.hasError)
        return failure!T(decoded.error.toString);
    return success(decoded.value);
}

/// Encodes `value` as a JSON string via `sparkles:wired` — compact by default
/// (token-efficient for agent prompts), pretty for human-readable artifacts.
Result!string encodeJson(T)(in T value, bool pretty = false)
{
    import std.array : appender;
    import sparkles.wired : writeJSON;
    import sparkles.wired.json.writer : JsonWriteOptions;

    // `writeJSON` is the writer-based primary form and takes its layout as a
    // compile-time option, so the runtime `pretty` flag picks between two
    // instantiations. Pretty is wired's SPEC §11.4 layout: 2-space indent,
    // `": "` separator, LF.
    auto buf = appender!string;
    auto encoded = pretty
        ? writeJSON!(JsonWriteOptions(pretty: true))(value, buf)
        : writeJSON!(JsonWriteOptions.init)(value, buf);
    if (encoded.hasError)
        return failure!string(encoded.error.toString);
    return success(buf[]);
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
    // Pretty is wired's SPEC §11.4 layout — 2-space indent, `": "`, LF (the
    // old expectation was std.json's 4-space `toPrettyString`).
    assert(encodeJson(Point(1, 2), pretty: true).value == "{\n  \"x\": 1,\n  \"y\": 2\n}");
}
