/**
Ingesting a TypeScript `twoslash` JSON payload into the
$(MREF sparkles,twoslash,protocol) node model.

The reference `twoslash` (and its `twoslash-vue` / `twoslash-eslint` siblings)
emit a `TwoslashReturn` as JSON: a top-level `code` string, a `nodes` array,
and assorted metadata (`meta`, `flags`, `compilerOptions`, …) this overlay
does not consume. Decoding runs through `sparkles:wired`, which walks the
struct fields and $(B ignores unknown JSON keys) — so the extra top-level
metadata and per-node fields we do not model (`target`, `tags`, `filename`,
`kindModifiers`, …) are dropped harmlessly, and a $(D hover) node missing the
$(D level)/$(D completions)/… fields decodes fine because every non-universal
$(REF Node, sparkles,twoslash,protocol) field is `@WireOptional`.

Not `@nogc` / `nothrow`: `std.json.parseJSON` and wired allocate. Errors are
returned as a `JsonResult` (an `Expected`), never thrown.
*/
module sparkles.twoslash.ingest;

import std.json : JSONValue, parseJSON;

import sparkles.wired.json : fromJSON, JsonResult, readJSONFile;

import sparkles.twoslash.protocol : TwoslashReturn;

/// Decodes an already-parsed `TwoslashReturn` JSON object.
JsonResult!TwoslashReturn fromTwoslashJson(JSONValue root)
    => fromJSON!TwoslashReturn(root);

/// Parses and decodes a twoslash JSON payload from a string, without throwing.
JsonResult!TwoslashReturn parseTwoslash(scope const(char)[] json)
{
    JSONValue root;
    try
        root = parseJSON(json);
    catch (Exception e)
        return JsonResult!TwoslashReturn(new Exception("twoslash: invalid JSON: " ~ e.msg));
    return fromTwoslashJson(root);
}

/// Reads, parses, and decodes a twoslash JSON file, without throwing.
JsonResult!TwoslashReturn loadTwoslashFile(string path)
    => readJSONFile!TwoslashReturn(path);

version (unittest)
{
    import sparkles.twoslash.protocol : NodeType;

    // A representative payload exercising every node kind, in the exact field
    // shapes the reference emits (extra fields — target, tags, filename,
    // kindModifiers, sortText, and the top-level flags — are present on purpose
    // to prove they are ignored, not rejected).
    private enum sampleJson = `{
        "code": "const a = 1\nconst b = a\n",
        "flags": {},
        "nodes": [
            { "type": "hover", "start": 6, "length": 1, "line": 0, "character": 6,
              "target": "a", "text": "const a: 1" },
            { "type": "query", "start": 18, "length": 1, "line": 1, "character": 6,
              "target": "b", "text": "const b: number", "docs": "the sum" },
            { "type": "highlight", "start": 0, "length": 5, "line": 0, "character": 0 },
            { "type": "error", "start": 18, "length": 1, "line": 1, "character": 6,
              "code": 2339, "id": "err-2339", "filename": "index.ts",
              "text": "Property does not exist.", "level": "error" },
            { "type": "completion", "start": 10, "length": 0, "line": 0, "character": 10,
              "completionsPrefix": "a",
              "completions": [ { "name": "at", "kind": "method", "kindModifiers": "", "sortText": "11" } ] },
            { "type": "tag", "start": 0, "length": 0, "line": 0, "character": 0,
              "name": "log", "text": "hello" }
        ]
    }`;
}

@("ingest.parseTwoslash.allNodeKinds")
unittest
{
    auto res = parseTwoslash(sampleJson);
    assert(!res.hasError, res.hasError ? res.error.msg : "");
    const tw = res.value;

    assert(tw.code == "const a = 1\nconst b = a\n");
    assert(tw.nodes.length == 6);

    // The `type` discriminant maps verbatim (lowercase → NodeType, wired's
    // default CaseStyle.original). If this breaks, a wired case-policy default
    // changed and every node would silently mis-decode.
    assert(tw.nodes[0].type == NodeType.hover);
    assert(tw.nodes[1].type == NodeType.query);
    assert(tw.nodes[2].type == NodeType.highlight);
    assert(tw.nodes[3].type == NodeType.error);
    assert(tw.nodes[4].type == NodeType.completion);
    assert(tw.nodes[5].type == NodeType.tag);
}

@("ingest.parseTwoslash.payloadFields")
unittest
{
    const tw = parseTwoslash(sampleJson).value;

    // hover: text present, docs absent (defaults to "").
    assert(tw.nodes[0].text == "const a: 1");
    assert(tw.nodes[0].docs == "");
    assert(tw.nodes[0].start == 6 && tw.nodes[0].length == 1);
    assert(tw.nodes[0].line == 0 && tw.nodes[0].character == 6);
    assert(tw.nodes[0].end == 7);

    // query carries docs.
    assert(tw.nodes[1].docs == "the sum");

    // error: level + numeric code + id; the extra `filename` was ignored.
    assert(tw.nodes[3].level == "error");
    assert(tw.nodes[3].code == 2339);
    assert(tw.nodes[3].id == "err-2339");

    // completion: prefix + one candidate (extra kindModifiers/sortText ignored).
    assert(tw.nodes[4].completionsPrefix == "a");
    assert(tw.nodes[4].completions.length == 1);
    assert(tw.nodes[4].completions[0].name == "at");
    assert(tw.nodes[4].completions[0].kind == "method");

    // tag: name + text.
    assert(tw.nodes[5].name == "log");
    assert(tw.nodes[5].text == "hello");
}

@("ingest.parseTwoslash.invalidJson")
unittest
{
    auto res = parseTwoslash(`{ not valid `);
    assert(res.hasError);
}

@("ingest.parseTwoslash.emptyNodes")
unittest
{
    auto res = parseTwoslash(`{ "code": "x", "nodes": [] }`);
    assert(!res.hasError);
    assert(res.value.nodes.length == 0);
    assert(res.value.code == "x");
}
