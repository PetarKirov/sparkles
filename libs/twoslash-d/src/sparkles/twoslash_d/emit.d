/**
Emitting a D-native `TwoslashReturn` as a `.twoslash.json` payload.

Thin wrappers over `sparkles:wired` that enforce the D producer contract
(spec `NTN4`): the payload always declares `language` (default `"d"`) and
`offsetEncoding: "utf-8"`, so ingest never runs the UTF-16 legacy remap over
byte-offset-native nodes.
*/
module sparkles.twoslash_d.emit;

import sparkles.twoslash.protocol : TwoslashReturn;

import sparkles.wired.json : JsonResult, writeJSONFile;
import sparkles.wired.json.writer : JsonWriteOptions, KeyOrder;

/**
The on-disk layout of a `.twoslash.json` payload: four-space indent with
sorted object keys.

Pinned explicitly rather than left to `writeJSONFile`'s defaults. The
fixtures under `apps/twoslash-extract/examples/fixtures/` are checked in,
and `--verify` compares *parsed* documents — so a change to wired's default
layout reformats all 36 of them without any test going red. That already
happened once (`e630631d` regenerated 6412 lines for no semantic reason)
when wired moved off `std.json`; these options reproduce the `std.json`
shape those fixtures were written in.
*/
enum JsonWriteOptions twoslashPayloadLayout = JsonWriteOptions(
    pretty: true,
    indent: "    ",
    keyOrder: KeyOrder.sorted,
);

/// Stamps the D-producer declaration onto `tw` (idempotent).
ref TwoslashReturn declareDPayload(return ref TwoslashReturn tw,
    string language = "d") @safe pure nothrow @nogc
{
    if (!tw.language.length)
        tw.language = language;
    tw.offsetEncoding = "utf-8";
    return tw;
}

/// Writes `tw` to `path` in the reference fixture shape
/// ($(LREF twoslashPayloadLayout)), with the D-producer declaration applied.
JsonResult!void writeTwoslashFile(TwoslashReturn tw, string path)
{
    declareDPayload(tw);
    return writeJSONFile!twoslashPayloadLayout(tw, path);
}

@("emit.writeTwoslashFile.roundTrip")
@system unittest
{
    import std.file : remove, tempDir;
    import std.path : buildPath;

    import sparkles.twoslash.ingest : loadTwoslashFile;
    import sparkles.twoslash.protocol : Node, NodeType;

    // Non-ASCII before the decorated token: the exact case the utf-8
    // declaration protects (an undeclared payload would be corrupted by the
    // legacy UTF-16 remap on load).
    auto tw = TwoslashReturn(
        code: "// — dash\nauto x = 1;\n",
        nodes: [Node(type: NodeType.hover, start: 17, length: 1, line: 1,
            character: 5, text: "int x")]);

    const path = buildPath(tempDir, "sparkles-twoslash-d-emit-test.twoslash.json");
    scope (exit) remove(path);
    auto written = writeTwoslashFile(tw, path);
    assert(!written.hasError, written.hasError ? written.error.toString() : "");

    const back = loadTwoslashFile(path).value;
    assert(back.language == "d");
    assert(back.offsetEncoding == "utf-8");
    assert(back.nodes[0].start == 17); // byte offset survived the round trip
    assert(back.code[back.nodes[0].start .. back.nodes[0].start + 1] == "x");
}
