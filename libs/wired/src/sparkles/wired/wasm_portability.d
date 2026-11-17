/++
`sparkles:wired` on WebAssembly (docs/specs/wired/wasm, WW15): each format's
document reader and writer, its typed codec, and its error reporting, run
under `dub test :wired -- --wasm` as a `wasm32-unknown-wasip1` program and,
like every test, natively.

The tests use the public API only, each importing what it needs, as an
extracted test sees nothing of the module it was written in.
+/
module sparkles.wired.wasm_portability;

import sparkles.test_runner.attributes : wasm;

@("wired.wasm.json.typedRoundTrip") @wasm
@safe unittest
{
    import sparkles.wired : fromJSON, toJSON;

    static struct Server
    {
        string host;
        ushort port;
        string[] tags;
        double load;
        bool up;
        long[string] limits;
    }

    const decoded = fromJSON!Server(`{"host": "hé", "port": 8080, "tags": ["a", "b"],`
        ~ ` "load": 0.25, "up": true, "limits": {"cpu": -3}}`);
    assert(decoded.hasValue);
    assert(decoded.value.host == "hé" && decoded.value.port == 8080);
    assert(decoded.value.tags == ["a", "b"] && decoded.value.load == 0.25 && decoded.value.up);
    assert(decoded.value.limits["cpu"] == -3);

    const encoded = toJSON(decoded.value);
    assert(encoded.hasValue);
    const again = fromJSON!Server(encoded.value[]);
    assert(again.hasValue && again.value == decoded.value);
}

@("wired.wasm.json.documentAndErrors") @wasm
@safe unittest
{
    import sparkles.wired : fromJSON;
    import sparkles.wired.json : parseJsonDocument;

    {
        const parsed = parseJsonDocument(`{"a": [1, 2.5e3, null, "😀"], "b": {}}`);
        assert(parsed.hasValue);
    }
    assert(parseJsonDocument(`{"a": [1, }`).hasError);
    assert(fromJSON!int(`"not a number"`).hasError);
    assert(fromJSON!ubyte("300").hasError, "out of range");
}

@("wired.wasm.sdl.typedRoundTrip") @wasm
@safe unittest
{
    import sparkles.wired.sdl : fromSDL, toSDL;

    static struct Dependency
    {
        string name;
        string version_;
    }

    static struct Package
    {
        string name;
        string[] authors;
        int port;
        bool enabled;
        Dependency[] dependencies;
    }

    const decoded = fromSDL!Package("name \"p\"\nauthors \"a\" \"b\"\nport 443\nenabled true\n"
        ~ "dependencies {\n    name \"d\"\n    version_ \"1.2\"\n}\n");
    assert(decoded.hasValue, decoded.error.toString);
    assert(decoded.value.name == "p" && decoded.value.authors == ["a", "b"]);
    assert(decoded.value.port == 443 && decoded.value.enabled);

    const encoded = toSDL(decoded.value);
    assert(encoded.hasValue);
    const again = fromSDL!Package(encoded.value[]);
    assert(again.hasValue && again.value == decoded.value);
}

@("wired.wasm.sdl.documentWriterAndErrors") @wasm
@safe unittest
{
    import std.array : appender;
    import sparkles.wired.sdl : SdlErrorCode, parseSdlDocument, writeSdlDocument;

    const text = "// a comment\nnode 1 2.5 \"s\" true null key=\"v\" {\n    child `raw`\n}\n";
    auto parsed = parseSdlDocument(text);
    assert(parsed.hasValue);
    auto written = appender!string;
    assert(!writeSdlDocument(parsed.document, written).hasError);
    assert(written[].length);
    auto reparsed = parseSdlDocument(written[]);
    assert(reparsed.hasValue);

    const unterminated = parseSdlDocument("name \"x\n");
    assert(unterminated.hasError);
    assert(unterminated.error.code == SdlErrorCode.unterminatedString);
    assert(unterminated.error.startPosition.line == 1);
}
