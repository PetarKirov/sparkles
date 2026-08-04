/**
JSONTestSuite conformance runner (SPEC §11.5).

Drives the reader over the pinned nst/JSONTestSuite corpus
(`test_parsing/`): every `y_*` file must parse, every `n_*` file must be
rejected, and `i_*` files may go either way but must never crash. The
corpus location comes from `$JSON_TEST_SUITE` (exported by the nix
devshell); without it the test logs a skip notice and passes, so plain
`dub test :wired` works outside the shell. The companion nativejson-benchmark
test checks its JSON_checker pass/fail files and all roundtrip inputs through
`$NATIVEJSON_TEST_SUITE`.
*/
module sparkles.wired.json.conformance;

version (unittest):

@("conformance.jsonTestSuite")
@system unittest
{
    import std.file : dirEntries, read, SpanMode;
    import std.path : baseName;
    import std.process : environment;
    import std.stdio : stderr;

    import sparkles.wired.json.reader : isValidJson, parseJsonDocument;

    const root = environment.get("JSON_TEST_SUITE");
    if (root is null)
    {
        stderr.writeln("conformance.jsonTestSuite: $JSON_TEST_SUITE not set — skipping");
        return;
    }

    size_t accepted, rejected, indeterminate, failures;
    foreach (entry; dirEntries(root ~ "/test_parsing", "*.json", SpanMode.shallow))
    {
        const name = entry.name.baseName;
        // The corpus is byte-oriented (some files are deliberately not
        // valid UTF-8, some not even valid text) — feed raw bytes.
        const bytes = cast(const(char)[]) read(entry.name);

        const result = parseJsonDocument(bytes);
        const parsed = result.hasValue;

        // The text-level validator must agree with the parser everywhere.
        if (isValidJson(bytes) != parsed)
        {
            failures++;
            stderr.writefln!"  validator/parser disagree: %s"(name);
        }

        switch (name[0])
        {
        case 'y':
            accepted++;
            if (!parsed)
            {
                failures++;
                stderr.writefln!"  must-accept failed: %s (%s at byte %s)"(
                    name, result.error.code, result.error.offset);
            }
            break;
        case 'n':
            rejected++;
            if (parsed)
            {
                failures++;
                stderr.writefln!"  must-reject failed: %s"(name);
            }
            break;
        case 'i':
            indeterminate++; // either verdict is fine; not crashing is the test
            break;
        default:
            break;
        }
    }

    assert(accepted + rejected + indeterminate > 300,
        "corpus looks truncated — expected the full JSONTestSuite");
    assert(failures == 0, "JSONTestSuite conformance failures (see stderr)");
}

@("conformance.nativejsonBenchmark")
@system unittest
{
    import std.algorithm.searching : endsWith, startsWith;
    import std.file : dirEntries, read, SpanMode;
    import std.path : baseName;
    import std.process : environment;
    import std.stdio : stderr;

    import sparkles.wired.json.reader : isValidJson, parseJsonDocument;

    const root = environment.get("NATIVEJSON_TEST_SUITE");
    if (root is null)
    {
        stderr.writeln("conformance.nativejsonBenchmark: "
            ~ "$NATIVEJSON_TEST_SUITE not set — skipping");
        return;
    }

    size_t accepted, rejected, roundtrips, failures;
    foreach (entry; dirEntries(root ~ "/data/jsonchecker", "*.json",
        SpanMode.shallow))
    {
        const name = entry.name.baseName;
        if (name.endsWith("_EXCLUDE.json"))
            continue; // valid RFC 8259 or implementation-depth-policy cases

        const bytes = cast(const(char)[]) read(entry.name);
        const parsed = parseJsonDocument(bytes).hasValue;
        if (isValidJson(bytes) != parsed)
        {
            failures++;
            stderr.writefln!"  validator/parser disagree: %s"(name);
        }

        if (name.startsWith("pass"))
        {
            accepted++;
            if (!parsed)
            {
                failures++;
                stderr.writefln!"  must-accept failed: %s"(name);
            }
        }
        else if (name.startsWith("fail"))
        {
            rejected++;
            if (parsed)
            {
                failures++;
                stderr.writefln!"  must-reject failed: %s"(name);
            }
        }
    }

    foreach (entry; dirEntries(root ~ "/data/roundtrip", "*.json",
        SpanMode.shallow))
    {
        const name = entry.name.baseName;
        const bytes = cast(const(char)[]) read(entry.name);
        const result = parseJsonDocument(bytes);
        roundtrips++;
        if (!result.hasValue)
        {
            failures++;
            stderr.writefln!"  roundtrip input rejected: %s (%s at byte %s)"(
                name, result.error.code, result.error.offset);
        }
        if (isValidJson(bytes) != result.hasValue)
        {
            failures++;
            stderr.writefln!"  roundtrip validator/parser disagree: %s"(name);
        }
    }

    assert(accepted == 3 && rejected == 31 && roundtrips == 27,
        "nativejson corpus looks truncated");
    assert(failures == 0,
        "nativejson-benchmark conformance failures (see stderr)");
}
