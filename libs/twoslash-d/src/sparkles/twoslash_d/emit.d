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

/// Stamps the D-producer declaration onto `tw` (idempotent).
ref TwoslashReturn declareDPayload(return ref TwoslashReturn tw,
    string language = "d") @safe pure nothrow @nogc
{
    if (!tw.language.length)
        tw.language = language;
    tw.offsetEncoding = "utf-8";
    return tw;
}

/// Writes `tw` to `path` in the reference fixture shape (2-space pretty
/// JSON via wired), with the D-producer declaration applied.
JsonResult!void writeTwoslashFile(TwoslashReturn tw, string path)
{
    declareDPayload(tw);
    return writeJSONFile(tw, path);
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
