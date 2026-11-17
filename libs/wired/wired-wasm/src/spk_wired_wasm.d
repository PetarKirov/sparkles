/++
`sparkles:wired` as the documentation site's WebAssembly module
(docs/specs/wired/wasm WW12, and the npm package of WW13): the shared memory
interface of $(MREF sparkles, base, wasm) plus `spk_wired_run`, which answers
one JSON request with one JSON response. A `wasip1` reactor built by
`dub build :wired-wasm --arch=wasm32-unknown-wasip1`
(docs/specs/toolchain/wasm-modules.md).

A request is `{ "op": …, "format": "json" | "sdl", "text": …, "name": … }`:

$(UL
    $(LI `parse` answers `{ "tree": … }`: for JSON the value itself; for SDL
        the top-level tags as `{ name, line, values, attributes, children }`,
        each value `{ kind, text }` with `text` its canonical SDL spelling;)
    $(LI `format` answers `{ "text": … }`, the document written canonically
        (SDL) or indented by two spaces (JSON), members in source order;)
    $(LI `recipe` answers `{ "recipe": … }` or `{ "error": … }` exactly as the
        Nix module does (WW4, WW5), the format chosen by `name` as
        `parseDubRecipeText` chooses it.)
)

Text that does not parse answers `{ "error": { name, line, column, code,
message } }`; a request that is not one of these answers
`{ "fault": message }`.
+/
module spk_wired_wasm;

import std.array : Appender, appender;
import std.json : JSONException, JSONType, JSONValue, parseJSON;

import sparkles.test_runner.attributes : wasm;

/// The response to the JSON `request`, as JSON.
string wiredRun(scope const(char)[] request) @safe
{
    JSONValue r;
    try
        r = parseJSON(request);
    catch (JSONException e)
        return fault("the request is not JSON: " ~ e.msg);
    if (r.type != JSONType.object)
        return fault("the request must be an object");

    string field(string key)
    {
        const v = key in r;
        return v !is null && v.type == JSONType.string ? v.str : null;
    }
    const op = field("op"), format = field("format"), text = field("text");
    const name = field("name").length ? field("name") : format == "json" ? "dub.json" : "dub.sdl";
    if (text is null)
        return fault("the request's `text` must be a string");

    if (op == "recipe")
        return recipeOf(text, name);
    if (format == "json" && (op == "parse" || op == "format"))
        return jsonOf(text, name, op == "format");
    if (format == "sdl" && (op == "parse" || op == "format"))
        return sdlOf(text, name, op == "format");
    return fault("unknown op/format: " ~ op ~ "/" ~ format);
}

private string fault(string message) @safe
{
    auto w = appender!string;
    w.put(`{"fault":`);
    putString(w, message);
    w.put('}');
    return w[];
}

private string recipeOf(scope const(char)[] text, string name) @safe
{
    import sparkles.dub_manifest_nix.convert : respond;
    import sparkles.dub_manifest_nix.tree_host : TreeHost;

    TreeHost host;
    const(char)[][2] names = ["text", "name"];
    TreeHost.Value[2] values = [host.string_(text), host.string_(name)];
    return host.json(respond(host, host.attrs(names[], values[])).value);
}

private string errorJson(string name, size_t line, size_t column, scope const(char)[] code,
    scope const(char)[] message) @safe
{
    import std.conv : to;

    auto w = appender!string;
    w.put(`{"error":{"code":`);
    putString(w, code);
    w.put(`,"column":`);
    w.put(column.to!string);
    w.put(`,"line":`);
    w.put(line.to!string);
    w.put(`,"message":`);
    putString(w, message);
    w.put(`,"name":`);
    putString(w, name);
    w.put("}}");
    return w[];
}

// --- JSON -----------------------------------------------------------------

private string jsonOf(scope const(char)[] text, string name, bool asText) @safe
{
    import std.conv : to;
    import sparkles.wired.json : parseJsonDocument;

    auto parsed = parseJsonDocument(text);
    if (parsed.hasError)
    {
        // The reader reports a byte offset; lines and columns count from 1.
        size_t line = 1, column = 1;
        foreach (i, c; text[0 .. parsed.error.offset < text.length ? parsed.error.offset : text.length])
        {
            if (c == '\n')
            {
                ++line;
                column = 1;
            }
            else if ((c & 0xC0) != 0x80)
                ++column;
        }
        return errorJson(name, line, column, parsed.error.code.to!string,
            "Cannot parse JSON: " ~ parsed.error.code.to!string);
    }
    auto w = appender!string;
    if (asText)
    {
        auto body = appender!string;
        putJson(body, parsed.document.root, 0, true);
        body.put('\n');
        w.put(`{"text":`);
        putString(w, body[]);
        w.put('}');
    }
    else
    {
        w.put(`{"tree":`);
        putJson(w, parsed.document.root, 0, false);
        w.put('}');
    }
    return w[];
}

private void putJson(W, V)(ref W w, scope V v, size_t depth, bool indent)
{
    import sparkles.wired.json : JsonKind;
    import sparkles.wired.json.writer : writeJsonDouble, writeJsonLong, writeJsonUlong;

    void newline(size_t d)
    {
        if (!indent)
            return;
        w.put('\n');
        foreach (_; 0 .. d)
            w.put("  ");
    }

    final switch (v.kind)
    {
    case JsonKind.none, JsonKind.null_:
        w.put("null");
        break;
    case JsonKind.bool_:
        w.put(v.boolean ? "true" : "false");
        break;
    case JsonKind.integer:
        writeJsonLong(w, v.integer);
        break;
    case JsonKind.uinteger:
        writeJsonUlong(w, v.uinteger);
        break;
    case JsonKind.floating:
        writeJsonDouble(w, v.floating);
        break;
    case JsonKind.rawNumber:
        w.put(v.raw);
        break;
    case JsonKind.string_:
        putString(w, v.str);
        break;
    case JsonKind.array:
        w.put('[');
        bool first = true;
        foreach (e; v.byElement)
        {
            if (!first)
                w.put(',');
            first = false;
            newline(depth + 1);
            putJson(w, e, depth + 1, indent);
        }
        if (!first)
            newline(depth);
        w.put(']');
        break;
    case JsonKind.object:
        w.put('{');
        bool first = true;
        foreach (m; v.byKeyValue)
        {
            if (!first)
                w.put(',');
            first = false;
            newline(depth + 1);
            putString(w, m.key);
            w.put(indent ? ": " : ":");
            putJson(w, m.value, depth + 1, indent);
        }
        if (!first)
            newline(depth);
        w.put('}');
        break;
    }
}

private void putString(W)(ref W w, scope const(char)[] s)
{
    import sparkles.wired.json.writer : writeJsonString;

    writeJsonString(w, s);
}

// --- SDL ------------------------------------------------------------------

private string sdlOf(scope const(char)[] text, string name, bool asText) @safe
{
    import std.conv : to;
    import sparkles.wired.sdl : parseSdlDocument, writeSdlDocument;

    // The reader is memory-safe, but here dip1000 infers its lexer's `fail`
    // `@system` (a `scope` `this` assigning an error), though the same call
    // infers `@safe` in sparkles:wired's own tests.
    auto parsed = (() @trusted => parseSdlDocument(text, name))();
    if (parsed.hasError)
    {
        auto error = parsed.error.toString();
        // The fields carry the position; the message is the reason alone.
        const prefix = name ~ "(" ~ parsed.error.startPosition.line.to!string ~ ":"
            ~ parsed.error.startPosition.column.to!string ~ "): ";
        if (error.length >= prefix.length && error[0 .. prefix.length] == prefix)
            error = error[prefix.length .. $];
        return errorJson(name, parsed.error.startPosition.line,
            parsed.error.startPosition.column, parsed.error.code.to!string, error);
    }
    auto w = appender!string;
    if (asText)
    {
        auto body = appender!string;
        const written = writeSdlDocument(parsed.document, body);
        if (written.hasError)
            return fault(written.error.toString());
        w.put(`{"text":`);
        putString(w, body[]);
        w.put('}');
        return w[];
    }
    w.put(`{"tree":[`);
    bool first = true;
    foreach (child; parsed.document.root.byChild)
    {
        if (!first)
            w.put(',');
        first = false;
        putNode(w, parsed.document, child);
    }
    w.put("]}");
    return w[];
}

private void putNode(W, D, N)(ref W w, ref D document, scope N node)
{
    import std.conv : to;

    w.put(`{"name":`);
    putName(w, node.qualifiedName);
    w.put(`,"line":`);
    w.put(document.position(node.span.bytes.startOffset).line.to!string);
    w.put(`,"values":[`);
    bool first = true;
    foreach (v; node.byValue)
    {
        if (!first)
            w.put(',');
        first = false;
        putScalar(w, v);
    }
    w.put(`],"attributes":[`);
    first = true;
    foreach (a; node.byAttribute)
    {
        if (!first)
            w.put(',');
        first = false;
        w.put(`{"name":`);
        putName(w, a.qualifiedName);
        w.put(`,"value":`);
        putScalar(w, a.value);
        w.put('}');
    }
    w.put(`],"children":[`);
    first = true;
    foreach (c; node.byChild)
    {
        if (!first)
            w.put(',');
        first = false;
        putNode(w, document, c);
    }
    w.put("]}");
}

private void putName(W, Q)(ref W w, scope Q name)
{
    putString(w, name.namespace_.length ? name.namespace_ ~ ":" ~ name.localName : name.localName);
}

private void putScalar(W, S)(ref W w, scope S scalar)
{
    import std.conv : to;
    import sparkles.wired.sdl : writeSdlScalar;

    auto spelling = appender!string;
    writeSdlScalar(scalar, spelling);
    // The kind's D member name, a keyword's trailing `_` dropped (`string_`).
    const kind = scalar.kind.to!string;
    w.put(`{"kind":`);
    putString(w, kind.length && kind[$ - 1] == '_' ? kind[0 .. $ - 1] : kind);
    w.put(`,"text":`);
    putString(w, spelling[]);
    w.put('}');
}

///
@("spk_wired_wasm.wiredRun.sdl") @wasm
@safe unittest
{
    assert(wiredRun(`{"op": "parse", "format": "sdl", "text": "a 1 k=\"v\" {\n  b\n}\n"}`)
        == `{"tree":[{"name":"a","line":1,"values":[{"kind":"integer","text":"1"}],`
        ~ `"attributes":[{"name":"k","value":{"kind":"string","text":"\"v\""}}],`
        ~ `"children":[{"name":"b","line":2,"values":[],"attributes":[],"children":[]}]}]}`,
        wiredRun(`{"op": "parse", "format": "sdl", "text": "a 1 k=\"v\" {\n  b\n}\n"}`));
    assert(wiredRun(`{"op": "format", "format": "sdl", "text": "a   1\n"}`) == `{"text":"a 1\n"}`);
    assert(wiredRun(`{"op": "parse", "format": "sdl", "text": "a \"x\n"}`)[0 .. 10] == `{"error":{`);
}

@("spk_wired_wasm.wiredRun.json") @wasm
@safe unittest
{
    import std.json : parseJSON;

    assert(wiredRun(`{"op": "parse", "format": "json", "text": "{\"b\": [1, 2.5], \"a\": null}"}`)
        == `{"tree":{"b":[1,2.5],"a":null}}`);
    assert(wiredRun(`{"op": "format", "format": "json", "text": "{\"a\":[1,{}]}"}`)
        == `{"text":"{\n  \"a\": [\n    1,\n    {}\n  ]\n}\n"}`);
    const e = wiredRun(`{"op": "parse", "format": "json", "text": "{\n  \"a\": ]"}`);
    assert(e[0 .. 10] == `{"error":{` && parseJSON(e)["error"]["line"].integer == 2, e);
}

@("spk_wired_wasm.wiredRun.recipe") @wasm
@safe unittest
{
    import std.json : parseJSON;

    assert(wiredRun(`{"op": "recipe", "format": "sdl", "text": "name \"x\"\n"}`)
        == `{"recipe":{"name":"x"}}`);
    assert(wiredRun(`{"op": "recipe", "format": "json", "text": "{\"name\": \"j\"}"}`)
        == `{"recipe":{"name":"j"}}`);
    const e = wiredRun(`{"op": "recipe", "format": "sdl", "text": "targetTyp \"x\"\n"}`);
    assert(parseJSON(e)["error"]["code"].str == "unknownMember", e);
}

@("spk_wired_wasm.wiredRun.faults") @wasm
@safe unittest
{
    assert(wiredRun(`nope`)[0 .. 9] == `{"fault":`);
    assert(wiredRun(`[]`)[0 .. 9] == `{"fault":`);
    assert(wiredRun(`{"op": "parse", "format": "yaml", "text": ""}`)[0 .. 9] == `{"fault":`);
    assert(wiredRun(`{"op": "parse", "format": "sdl"}`)[0 .. 9] == `{"fault":`);
}

version (WASI)
{
    import sparkles.base.wasm : hostSlice, memoryBytes, validRanges;

    /++
    Answers the JSON request at `inPtr` into `outCap` bytes at `outPtr`
    ($(LREF wiredRun)). Returns the response's length, or `-1` when it does
    not fit or a range lies outside memory or overlaps the other.
    +/
    extern (C) export int spk_wired_run(uint inPtr, uint inLen, uint outPtr, uint outCap)
        @system
    {
        if (!validRanges(memoryBytes, inPtr, inLen, outPtr, outCap))
            return -1;
        const response = wiredRun(hostSlice!char(inPtr, inLen));
        if (response.length > outCap)
            return -1;
        hostSlice!char(outPtr, outCap)[0 .. response.length] = response;
        return cast(int) response.length;
    }
}
