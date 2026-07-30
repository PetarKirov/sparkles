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

/// Decodes an already-parsed `TwoslashReturn` JSON object, normalizing node
/// offsets to UTF-8 bytes (see $(LREF utf16ToUtf8Offsets)). A payload that
/// declares `offsetEncoding: "utf-8"` (a D-native producer) is already in
/// byte offsets and passes through untouched.
JsonResult!TwoslashReturn fromTwoslashJson(JSONValue root)
{
    auto res = fromJSON!TwoslashReturn(root);
    if (!res.hasError && res.value.offsetEncoding != "utf-8")
        utf16ToUtf8Offsets(res.value);
    return res;
}

/// Parses and decodes a twoslash JSON payload from a string, without throwing.
JsonResult!TwoslashReturn parseTwoslash(scope const(char)[] json)
{
    import expected : err;
    import sparkles.base.text.errors : ParseErrorCode;
    import sparkles.wired.json.error : JsonError, JsonStage;

    JSONValue root;
    try
        root = parseJSON(json);
    catch (Exception e)
    {
        // `std.json` reports the failure as a thrown exception with no
        // machine-readable detail, so carry its text as the parse-stage
        // reason; wired's own reader is the path that fills in line/column.
        JsonError parseFailed = {
            stage: JsonStage.parse,
            code: ParseErrorCode.unexpectedCharacter,
            reason: "twoslash: invalid JSON: " ~ e.msg,
        };
        return err!TwoslashReturn(parseFailed);
    }
    return fromTwoslashJson(root);
}

/// Reads, parses, and decodes a twoslash JSON file, without throwing.
JsonResult!TwoslashReturn loadTwoslashFile(string path)
{
    auto res = readJSONFile!TwoslashReturn(path);
    if (!res.hasError && res.value.offsetEncoding != "utf-8")
        utf16ToUtf8Offsets(res.value);
    return res;
}

/**
Rewrites every node's `start`/`length` from TypeScript's **UTF-16 code-unit**
offsets (what the reference `twoslash` emits — TS AST positions are UTF-16) into
**UTF-8 byte** offsets into `tw.code`, the coordinate system every renderer and
`sparkles:syntax` actually use. Without this a snippet containing any non-ASCII
before a decorated token (an em-dash in a comment, an accented identifier, an
emoji in a string) mis-positions every later hover/highlight/error — the offsets
drift by the extra UTF-8 bytes.

Pure-ASCII `code` is a fixed point (byte offset == UTF-16 offset), so the common
case is unchanged. Astral characters count as two UTF-16 units, matching TS; a
`character` column is a display column already (≈ UTF-16 for BMP), so it is left
as-is. Idempotent only on ASCII — call exactly once, at ingest, and only for
payloads that do not declare `offsetEncoding: "utf-8"` (a byte-offset-native
producer run through this would corrupt every offset after the first non-ASCII
character).
*/
void utf16ToUtf8Offsets(ref TwoslashReturn tw) @safe
{
    import std.utf : decode;

    const code = tw.code;
    // byteOf[u] = the UTF-8 byte offset of UTF-16 code unit `u`; the trailing
    // sentinel maps the end-of-string unit. An astral char spans two units, both
    // anchored to its start byte (a node boundary never splits a surrogate pair).
    size_t[] byteOf;
    byteOf.reserve(code.length + 1);
    size_t idx = 0;
    while (idx < code.length)
    {
        const at = idx;
        const c = decode(code, idx); // advances idx past the whole UTF-8 sequence
        byteOf ~= at;
        if (c > 0xFFFF)
            byteOf ~= at;
    }
    byteOf ~= code.length;

    size_t toByte(size_t u16) => byteOf[u16 < byteOf.length ? u16 : byteOf.length - 1];

    foreach (ref n; tw.nodes)
    {
        const byteStart = toByte(n.start);
        const byteEnd = toByte(n.start + n.length);
        n.start = byteStart;
        n.length = byteEnd - byteStart;
    }
}

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
    assert(!res.hasError, res.hasError ? res.error.toString : "");
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

@("ingest.utf16ToUtf8Offsets")
unittest
{
    // `code` has an em-dash (U+2014, 1 UTF-16 unit, 3 UTF-8 bytes) before the
    // decorated token, so TS's UTF-16 offset must be shifted +2 bytes.
    //   code:  "// — x\nconst y = x"
    //   UTF-16 index of `y` (line 1) = 6 (dash counts 1) + 1 (\n) + 6 = 13
    //   UTF-8  byte  of `y`          = 13 + 2 (dash's extra bytes) = 15
    const json = `{
        "code": "// — x\nconst y = x",
        "nodes": [
            { "type": "hover", "start": 13, "length": 1, "line": 1, "character": 6,
                "text": "const y: string" }
        ]
    }`;
    const tw = parseTwoslash(json).value;
    // The offset was remapped to the byte position, so slicing `code` yields the
    // right token — the whole point of the normalization.
    assert(tw.code[tw.nodes[0].start .. tw.nodes[0].end] == "y",
        tw.code[tw.nodes[0].start .. tw.nodes[0].end]);

    // Pure-ASCII code is a fixed point — offsets pass through unchanged.
    const ascii = parseTwoslash(
        `{ "code": "const y = x", "nodes": [` ~
        `{ "type": "hover", "start": 6, "length": 1, "line": 0, "character": 6, "text": "t" } ] }`).value;
    assert(ascii.nodes[0].start == 6 && ascii.nodes[0].length == 1);
    assert(ascii.code[ascii.nodes[0].start .. ascii.nodes[0].end] == "y");
}

@("ingest.parseTwoslash.utf8PassThrough")
unittest
{
    // A D-native producer emits byte offsets and declares them. The same
    // em-dash sample as above, but `start` is already the byte offset 15 —
    // running the UTF-16 remap over it would corrupt it (the exact bug the
    // declaration exists to prevent).
    const json = `{
        "code": "// — x\nconst y = x",
        "language": "d",
        "offsetEncoding": "utf-8",
        "nodes": [
            { "type": "hover", "start": 15, "length": 1, "line": 1, "character": 6,
                "text": "string y" }
        ]
    }`;
    const tw = parseTwoslash(json).value;
    assert(tw.effectiveLanguage == "d");
    assert(tw.nodes[0].start == 15); // untouched
    assert(tw.code[tw.nodes[0].start .. tw.nodes[0].end] == "y");
}

@("ingest.encode.legacyShapeUnchanged")
unittest
{
    // Encoding a legacy payload must not grow the new optional keys: absent
    // language/offsetEncoding stay absent (WireSkip.whenDefault), so re-encoded
    // TS fixtures keep their exact reference shape.
    import std.json : parseJSON;
    import sparkles.wired.json : toJSON;

    // wired encodes to text now, so the shape assertions parse it back.
    const tw = parseTwoslash(`{ "code": "x", "nodes": [] }`).value;
    const obj = parseJSON(toJSON(tw).value[]).object;
    assert("language" !in obj);
    assert("offsetEncoding" !in obj);

    // And a declared payload round-trips its declaration.
    const d = parseJSON(toJSON(TwoslashReturn(code: "x", language: "d",
        offsetEncoding: "utf-8")).value[]).object;
    assert(d["language"].str == "d");
    assert(d["offsetEncoding"].str == "utf-8");
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
