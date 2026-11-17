/++
`--check-wasm-modules`: the documentation site's WebAssembly modules agree
with the same D functions run natively (docs/specs/toolchain/wasm-modules.md,
`TCM9`).

A fixed corpus goes through both. Natively, through the functions the
modules export: `visibleWidthOf` and `segmentInto` for the text module,
`tableRender` for the table module, `wiredRun` for the wired module
(docs/specs/wired/wasm, WW12). In the modules, under node, through the
site's own loader (docs/.vitepress/theme/wasi.ts, `TCM7`): WASI preview 1 on
@bjorn3/browser_wasi_shim with a real clock, `_initialize` called once before
any export. The check names every case whose results differ: a miscompile,
a runtime feature missing on WebAssembly, or an interface mismatch. Whether
the functions are right is their packages' tests' business.
+/
module wasm_modules_check;

import std.json : JSONType, JSONValue, parseJSON;

import sparkles.base.wasm : segmentInto;
import spk_table_wasm : tableRender;
import spk_text_wasm : visibleWidthOf;
import spk_wired_wasm : wiredRun;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;

/// A text for the text module: its width, and its units in `slots` triples.
struct TextCase
{
    string name;
    string text;
    uint slots = 64; /// triple slots for `spk_segment`
}

/// A table specification for the table module, rendered into `outCap` bytes.
struct TableCase
{
    string name;
    string spec;
    uint outCap = 64 * 1024;
}

/// A request for the wired module, answered into `outCap` bytes.
struct WiredCase
{
    string name;
    string request;
    uint outCap = 64 * 1024;
}

/// The corpus: combining sequences, emoji modifiers and East Asian wide
/// characters among the texts; invalid JSON, invalid specifications and an
/// output buffer too small among the tables (`TCM9`).
immutable TextCase[] textCorpus = [
    TextCase("empty", ""),
    TextCase("ascii", "plain ascii text"),
    TextCase("combining marks", "é ä̲ ñ"),
    TextCase("emoji modifiers", "👍🏽 👋🏿 🧑🏻‍💻"),
    TextCase("emoji zwj family", "👨‍👩‍👧‍👦"),
    TextCase("regional indicators", "🇧🇬🇯🇵"),
    TextCase("east asian wide", "漢字かなカナ ｈｅｌｌｏ"),
    TextCase("hangul", "한국어 각"),
    TextCase("devanagari conjunct", "क्षि"),
    TextCase("zero width", "a​b‍c"),
    TextCase("escape sequences", "\x1b[1;31mred\x1b[0m \x1b]8;;https://dlang.org\x1b\\link\x1b]8;;\x1b\\"),
    TextCase("units past the slots", "abc", 2),
];

/// ditto
immutable TableCase[] tableCorpus = [
    TableCase("dense", `{"cells": [["a", "bb"], ["ccc", "d"]], "props": {"preset": "double"}}`),
    TableCase("header, spans and alignment",
        `{"cells": [["Name", "Qty", "Price"], [{"content": "apples", "colSpan": 2}, "1.50"],`
        ~ ` ["pears", "12", "13.25"]], "props": {"headerRows": 1, "rowSeparators": true,`
        ~ ` "columnAligns": ["left", "right", "decimal"], "title": "Fruit", "footer": "end"}}`),
    TableCase("sparse placements",
        `{"mode": "sparse", "placements": [{"row": 0, "col": 0, "content": "x", "rowSpan": 2},`
        ~ ` {"row": 0, "col": 1, "content": "y"}, {"row": 1, "col": 1, "content": "z"}],`
        ~ ` "props": {"preset": "heavy"}}`),
    TableCase("wide content wrapped",
        `{"cells": [["漢字の表", "👍🏽 ok"], ["été", "a long cell that wraps"]],`
        ~ ` "props": {"maxWidth": 20, "preset": "ascii"}}`),
    TableCase("glyph overrides",
        `{"cells": [["a", "b"]], "props": {"glyphs": {"cross": "*", "headerRow": {"horizontalLine": "="}}}}`),
    TableCase("no props", `{"cells": [["a"]]}`),
    TableCase("invalid json", `{"cells": [["a",`),
    TableCase("invalid json, message cut", `{"cells": [["a",`, 5),
    TableCase("unknown preset", `{"cells": [["a"]], "props": {"preset": "nope"}}`),
    TableCase("cells not an array", `{"cells": "a", "props": {}}`),
    TableCase("negative size", `{"cells": [["a"]], "props": {"headerRows": -1}}`),
    TableCase("output buffer too small", `{"cells": [["a", "bb"], ["ccc", "d"]], "props": {}}`, 16),
];

/// ditto: each operation in each format, text that does not parse, a
/// malformed request, and a response too large for its buffer.
immutable WiredCase[] wiredCorpus = [
    WiredCase("sdl parse", `{"op": "parse", "format": "sdl", "text": "a 1 2.5 \"s\" true null k=\"v\" {\n  b 2026/11/17 12:30:00\n}\n"}`),
    WiredCase("sdl format", `{"op": "format", "format": "sdl", "text": "a   1\n// c\nb \"x\" {\nc\n}\n"}`),
    WiredCase("sdl error", `{"op": "parse", "format": "sdl", "text": "a \"unterminated\n"}`),
    WiredCase("json parse", `{"op": "parse", "format": "json", "text": "{\"b\": [1, -2, 2.5e3, 18446744073709551615], \"a\": {\"\u00e9\": null}}"}`),
    WiredCase("json format", `{"op": "format", "format": "json", "text": "[1,{\"a\":[true,false]},\"\u6f22\"]"}`),
    WiredCase("json error", `{"op": "parse", "format": "json", "text": "{\n  \"a\": ]"}`),
    WiredCase("recipe sdl", `{"op": "recipe", "format": "sdl", "text": "name \"x\"\ndependency \"sparkles:base\" path=\"../..\"\nconfiguration \"library\" {\n  targetType \"library\"\n}\n"}`),
    WiredCase("recipe json", `{"op": "recipe", "format": "json", "text": "{\"name\": \"j\", \"dependencies\": {\"x\": \"~>1\"}}"}`),
    WiredCase("recipe error", `{"op": "recipe", "format": "sdl", "text": "targetTyp \"x\"\n"}`),
    WiredCase("fault", `{"op": "parse", "format": "yaml", "text": ""}`),
    WiredCase("response too large", `{"op": "format", "format": "sdl", "text": "a 1\n"}`, 4),
];

/// The request the node host reads: the corpus, as JSON.
string requestJson() @safe
{
    JSONValue[] texts, tables, wireds;
    foreach (c; textCorpus)
        texts ~= JSONValue(["text": JSONValue(c.text), "slots": JSONValue(long(c.slots))]);
    foreach (c; tableCorpus)
        tables ~= JSONValue(["spec": JSONValue(c.spec), "outCap": JSONValue(long(c.outCap))]);
    foreach (c; wiredCorpus)
        wireds ~= JSONValue(["request": JSONValue(c.request), "outCap": JSONValue(long(c.outCap))]);
    return JSONValue(["texts": JSONValue(texts), "tables": JSONValue(tables),
        "wireds": JSONValue(wireds)]).toString;
}

/// One text through the native functions, in the host's result shape.
JSONValue nativeText(const TextCase c) @safe
{
    auto triples = new uint[c.slots * 3];
    const n = segmentInto(c.text, triples);
    JSONValue[] units;
    if (n >= 0)
        foreach (t; triples[0 .. n * 3])
            units ~= JSONValue(long(t));
    return JSONValue(["width": JSONValue(long(visibleWidthOf(c.text))), "count": JSONValue(long(n)),
        "units": JSONValue(units)]);
}

/// One table through the native function, in the host's result shape.
JSONValue nativeTable(const TableCase c) @safe
{
    auto output = new char[c.outCap];
    const n = tableRender(c.spec, output);
    const length = n >= 0 ? n : n < -1 ? -n - 1 : 0;
    return JSONValue(["rc": JSONValue(long(n)), "output": JSONValue(output[0 .. length].idup)]);
}

/// One request through the native function, in the host's result shape:
/// the length or `-1`, and the response when it fits.
JSONValue nativeWired(const WiredCase c) @safe
{
    const response = wiredRun(c.request);
    const fits = response.length <= c.outCap;
    return JSONValue(["rc": JSONValue(fits ? long(response.length) : -1L),
        "output": JSONValue(fits ? response : "")]);
}

/// A case whose module result differs from the native one.
struct Mismatch
{
    string module_;
    string name;
    string native;
    string wasm;
}

/++
The cases where `results` (the host's reply) differs from the native
functions; a reply missing a case counts as a mismatch.
+/
Mismatch[] compare(const JSONValue results) @safe
{
    Mismatch[] found;
    const texts = results["texts"].arrayNoRef, tables = results["tables"].arrayNoRef;
    const wireds = "wireds" in results ? results["wireds"].arrayNoRef : null;
    foreach (i, c; textCorpus)
    {
        const native = nativeText(c);
        const wasm = i < texts.length ? texts[i] : JSONValue(null);
        if (native != wasm)
            found ~= Mismatch("text", c.name, native.toString, wasm.toString);
    }
    foreach (i, c; tableCorpus)
    {
        const native = nativeTable(c);
        const wasm = i < tables.length ? tables[i] : JSONValue(null);
        if (native != wasm)
            found ~= Mismatch("table", c.name, native.toString, wasm.toString);
    }
    foreach (i, c; wiredCorpus)
    {
        const native = nativeWired(c);
        const wasm = i < wireds.length ? wireds[i] : JSONValue(null);
        if (native != wasm)
            found ~= Mismatch("wired", c.name, native.toString, wasm.toString);
    }
    return found;
}

@("wasm_modules_check.compare.agreesWithItself")
@safe unittest
{
    JSONValue[] texts, tables, wireds;
    foreach (c; textCorpus)
        texts ~= nativeText(c);
    foreach (c; tableCorpus)
        tables ~= nativeTable(c);
    foreach (c; wiredCorpus)
        wireds ~= nativeWired(c);
    // Through text, as the host's reply arrives.
    const reply = (JSONValue[] t, JSONValue[] u) => parseJSON(JSONValue(["texts": JSONValue(t),
        "tables": JSONValue(u), "wireds": JSONValue(wireds)]).toString);
    assert(compare(reply(texts, tables)).length == 0);

    // A changed width, a missing table: two mismatches, named.
    texts[1] = JSONValue(["width": JSONValue(99)]);
    const found = compare(reply(texts, tables[0 .. $ - 1]));
    assert(found.length == 2);
    assert(found[0].module_ == "text" && found[0].name == "ascii");
    assert(found[1].name == "output buffer too small");
}

@("wasm_modules_check.corpus.coversTheErrorCodes")
@safe unittest
{
    import std.algorithm.searching : canFind;

    long[] codes;
    foreach (c; tableCorpus)
        codes ~= nativeTable(c)["rc"].integer;
    assert(codes.canFind!(n => n > 0), "a rendering");
    assert(codes.canFind(-1), "a rendering that does not fit");
    assert(codes.canFind!(n => n < -1), "an invalid specification");
    assert(nativeText(textCorpus[$ - 1])["count"].integer == -1, "units past the slots");
}

/++
The node host: each module instantiated by the site's loader, `wasi.ts` beside
the host, then the request's cases through the exports. Arguments: the text
module, the table module, the wired module, the request file and the file the JSON reply is
written to; stdout and stderr stay the modules'.
+/
enum string nodeHost = q{
import { readFileSync, writeFileSync } from "node:fs";
import { instantiateModule } from "./wasi.ts";

const load = (path) => instantiateModule(readFileSync(path));

const [textPath, tablePath, wiredPath, requestPath, replyPath] = process.argv.slice(2);
const request = JSON.parse(readFileSync(requestPath, "utf8"));
const text = await load(textPath), table = await load(tablePath), wired = await load(wiredPath);
const encoder = new TextEncoder(), decoder = new TextDecoder();

function put(x, s) {
    const bytes = encoder.encode(s);
    new Uint8Array(x.memory.buffer).set(bytes, x.spk_buf_ptr());
    return bytes.length;
}

const texts = request.texts.map(({ text: s, slots }) => {
    const length = put(text, s);
    const base = text.spk_buf_ptr();
    const width = text.spk_visible_width(base, length);
    const out = base + 128 * 1024;
    const count = text.spk_segment(base, length, out, slots);
    const units = count >= 0 ? [...new Uint32Array(text.memory.buffer, out, count * 3)] : [];
    return { width, count, units };
});

const tables = request.tables.map(({ spec, outCap }) => {
    const length = put(table, spec);
    const base = table.spk_buf_ptr();
    const out = base + 128 * 1024;
    const rc = table.spk_table_render(base, length, out, outCap);
    const k = rc >= 0 ? rc : rc < -1 ? -rc - 1 : 0;
    return { rc, output: decoder.decode(new Uint8Array(table.memory.buffer, out, k)) };
});

const wireds = request.wireds.map(({ request: r, outCap }) => {
    const length = put(wired, r);
    const base = wired.spk_buf_ptr();
    const out = base + 128 * 1024;
    const rc = wired.spk_wired_run(base, length, out, outCap);
    return { rc, output: rc >= 0 ? decoder.decode(new Uint8Array(wired.memory.buffer, out, rc)) : "" };
});

writeFileSync(replyPath, JSON.stringify({ texts, tables, wireds }));
};

/++
Runs the corpus through the modules at `textModule` and `tableModule` under
`node`, loaded by the site's `loader` (`wasi.ts`) with the WASI shim package
at `shim`, and compares with the native functions. Returns the process exit
status: `0` when every case agrees.
+/
RunExpected!void runCheckWasmModules(string textModule, string tableModule, string wiredModule, string loader,
    string shim)
{
    import std.file : copy, exists, mkdirRecurse, readText, rmdirRecurse, symlink, tempDir, write;
    import std.path : absolutePath, buildPath;
    import std.process : execute, thisProcessID;
    import std.conv : text;
    import std.stdio : stderr, writeln;

    foreach (path; [textModule, tableModule, wiredModule, loader, shim])
        if (path.length == 0 || !path.exists)
        {
            stderr.writeln("--check-wasm-modules: '", path, "' does not exist ",
                "(pass --text-module, --table-module, --wired-module, --wasi-loader and --wasi-shim)");
            return failRun("'" ~ path ~ "' does not exist");
        }

    const dir = buildPath(tempDir, text("ci-wasm-modules-", thisProcessID));
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    const host = buildPath(dir, "host.mjs"), request = buildPath(dir, "request.json"),
        reply = buildPath(dir, "reply.json");
    write(host, nodeHost);
    // The loader beside the host, resolving the shim through node_modules.
    copy(loader, buildPath(dir, "wasi.ts"));
    mkdirRecurse(buildPath(dir, "node_modules", "@bjorn3"));
    symlink(absolutePath(shim), buildPath(dir, "node_modules", "@bjorn3", "browser_wasi_shim"));
    write(request, requestJson());

    const run = execute(["node", "--no-warnings", host, textModule, tableModule, wiredModule, request, reply]);
    if (run.status != 0)
    {
        stderr.writeln("--check-wasm-modules: the node host failed (", run.status, "):\n", run.output);
        return failRun(text("the node host failed (", run.status, ")"));
    }

    const found = compare(parseJSON(readText(reply)));
    foreach (c; textCorpus)
        writeln(found.canFindCase("text", c.name) ? " ✗ " : " ✓ ", "text: ", c.name);
    foreach (c; tableCorpus)
        writeln(found.canFindCase("table", c.name) ? " ✗ " : " ✓ ", "table: ", c.name);
    foreach (c; wiredCorpus)
        writeln(found.canFindCase("wired", c.name) ? " ✗ " : " ✓ ", "wired: ", c.name);
    foreach (m; found)
        stderr.writeln(m.module_, ": ", m.name, "\n  native: ", m.native, "\n  wasm:   ", m.wasm);
    const cases = textCorpus.length + tableCorpus.length + wiredCorpus.length;
    writeln(cases - found.length, "/", cases, " cases agree");
    return found.length ? failRun(text(found.length, " case(s) disagree")) : ranOk();
}

private bool canFindCase(in Mismatch[] found, string module_, string name) @safe pure nothrow @nogc
{
    foreach (m; found)
        if (m.module_ == module_ && m.name == name)
            return true;
    return false;
}
