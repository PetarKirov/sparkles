/**
JSONTestSuite conformance runner (SPEC §11.5).

Drives the reader over the pinned nst/JSONTestSuite corpus
(`test_parsing/`): every `y_*` file must parse, every `n_*` file must be
rejected, and `i_*` files may go either way but must never crash. The
corpus location comes from `$JSON_TEST_SUITE` (exported by the nix
devshell); without it the test `skipTest`s, so plain `dub test :wired` works
outside the shell — and reports the corpus as skipped rather than passed.
`test_transform/` is covered separately: those files are all well-formed but
their _result_ is implementation-defined, so the suite prescribes no verdict
and this module pins wired's own choices as a golden table. The companion
nativejson-benchmark test checks its JSON_checker pass/fail files and all
roundtrip inputs through `$NATIVEJSON_TEST_SUITE`.
*/
module sparkles.wired.json.conformance;

version (unittest):

import sparkles.test_runner.skip : skipTest;

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
        skipTest("$JSON_TEST_SUITE not set (nix devshell exports it)");

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

/// The `test_transform/` corpus is the other half of the suite: every file is
/// structurally well-formed, but its *result* is implementation-defined —
/// integer range, float rounding, duplicate keys, lone surrogates, non-UTF-8
/// bytes. The suite prescribes no verdict, so instead of a pass/fail rule this
/// pins wired's own choices as a golden table: re-rendering the parsed document
/// makes the transform visible, so a silent change in number handling or key
/// policy fails here. Changing an entry is a deliberate policy decision.
@("conformance.jsonTestSuiteTransform")
@system unittest
{
    import std.file : dirEntries, read, SpanMode;
    import std.path : baseName;
    import std.process : environment;
    import std.stdio : stderr;

    import sparkles.wired.json.reader : isValidJson, parseJsonDocument;
    import sparkles.wired.json.writer : JsonSink, writeJson;

    const root = environment.get("JSON_TEST_SUITE");
    if (root is null)
        skipTest("$JSON_TEST_SUITE not set (nix devshell exports it)");

    static struct Transform
    {
        string file;
        /// The document re-rendered as minified JSON, or `null` when the
        /// reader must reject the input outright.
        string rendering;
    }

    // Numbers: everything representable exactly stays exact, including the
    // `long`-overflowing 9223372036854775808 and 10000000000000000999 (both
    // fit `ulong`). Only -9223372036854775809, which fits neither, falls back
    // to `double` — the rendering shows the precision it costs. Non-integers
    // take the usual IEEE-754 rounding: 1e-999 underflows to zero and
    // 1.000000000000000005 rounds to 1.0.
    //
    // Objects: duplicate keys are *preserved in order*, not deduplicated —
    // a DOM reports what the document said and leaves the policy to the
    // caller. NFC and NFD keys are distinct byte sequences and stay distinct
    // (no Unicode normalization on keys). `-0` keeps its sign by decoding as
    // a double, so it is distinguishable from `0`.
    //
    // Strings: escaped NULL survives a round trip, while both flavours of
    // broken code point are rejected — RFC 8259 requires valid UTF-8 for
    // interchange, so unpaired surrogates (`invalidSurrogate`) and raw
    // malformed bytes (`invalidUtf8`) are errors rather than replacement
    // characters. This is the strict choice; it is also the one the
    // `n_`-file verdicts above already commit to.
    static immutable Transform[] expected = [
        Transform("number_1.0.json", "[1.0]"),
        Transform("number_1.000000000000000005.json", "[1.0]"),
        Transform("number_1000000000000000.json", "[1000000000000000]"),
        Transform("number_10000000000000000999.json", "[10000000000000000999]"),
        Transform("number_1e-999.json", "[0.0]"),
        Transform("number_1e6.json", "[1000000.0]"),
        Transform("number_-9223372036854775808.json", "[-9223372036854775808]"),
        Transform("number_-9223372036854775809.json", "[-9223372036854776000.0]"),
        Transform("number_9223372036854775807.json", "[9223372036854775807]"),
        Transform("number_9223372036854775808.json", "[9223372036854775808]"),
        // Spelled with explicit escapes rather than literal accented
        // characters: the two keys are indistinguishable on screen and
        // differ only in bytes (U+00E9 vs. `e` + U+0301), which is the
        // entire point of the case.
        Transform("object_key_nfc_nfd.json",
            "{\"\u00E9\":\"NFC\",\"e\u0301\":\"NFD\"}"),
        Transform("object_key_nfd_nfc.json",
            "{\"e\u0301\":\"NFD\",\"\u00E9\":\"NFC\"}"),
        Transform("object_same_key_different_values.json", `{"a":1,"a":2}`),
        Transform("object_same_key_same_value.json", `{"a":1,"a":1}`),
        Transform("object_same_key_unclear_values.json", `{"a":0,"a":-0.0}`),
        Transform("string_1_escaped_invalid_codepoint.json", null),
        Transform("string_1_invalid_codepoint.json", null),
        Transform("string_2_escaped_invalid_codepoints.json", null),
        Transform("string_2_invalid_codepoints.json", null),
        Transform("string_3_escaped_invalid_codepoints.json", null),
        Transform("string_3_invalid_codepoints.json", null),
        // A wysiwyg string: the expected rendering holds the six literal
        // characters `\u0000`, because the writer re-escapes the NUL
        // instead of emitting a raw control byte.
        Transform("string_with_escaped_NULL.json", `["A\u0000B"]`),
    ];

    string[string] table;
    bool[string] mustReject;
    foreach (t; expected)
    {
        table[t.file] = t.rendering;
        if (t.rendering is null)
            mustReject[t.file] = true;
    }

    size_t checked, failures;
    foreach (entry; dirEntries(root ~ "/test_transform", "*.json", SpanMode.shallow))
    {
        const name = entry.name.baseName;
        const known = name in table;
        if (known is null)
        {
            failures++;
            stderr.writefln!"  unpinned transform file: %s (corpus pin moved?)"(name);
            continue;
        }
        checked++;

        // Byte-oriented like test_parsing — some inputs are not valid UTF-8.
        const bytes = cast(const(char)[]) read(entry.name);
        auto result = parseJsonDocument(bytes);

        // The text-level validator must agree with the parser here too.
        if (isValidJson(bytes) != result.hasValue)
        {
            failures++;
            stderr.writefln!"  validator/parser disagree: %s"(name);
        }

        if (name in mustReject)
        {
            if (result.hasValue)
            {
                failures++;
                stderr.writefln!"  must-reject failed: %s"(name);
            }
            continue;
        }

        if (!result.hasValue)
        {
            failures++;
            stderr.writefln!"  must-accept failed: %s (%s at byte %s)"(
                name, result.error.code, result.error.offset);
            continue;
        }

        JsonSink rendered;
        writeJson(result.document.root, rendered);
        if (rendered[] != *known)
        {
            failures++;
            stderr.writefln!"  transform changed: %s\n    expected %s\n    actual   %s"(
                name, *known, rendered[]);
        }
    }

    assert(checked == expected.length,
        "test_transform corpus looks truncated — expected every pinned file");
    assert(failures == 0, "JSONTestSuite test_transform failures (see stderr)");
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
        skipTest("$NATIVEJSON_TEST_SUITE not set (nix devshell exports it)");

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
