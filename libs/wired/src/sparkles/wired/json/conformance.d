/**
JSONTestSuite conformance runner (SPEC §11.5).

Drives the reader over the pinned nst/JSONTestSuite corpus
(`test_parsing/`): every `y_*` file must parse, every `n_*` file must be
rejected, and `i_*` files may go either way but must never crash. The
corpus location comes from `$JSON_TEST_SUITE` (exported by the nix
devshell); without it the test logs a skip notice and passes, so plain
`dub test :wired` works outside the shell.
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

    import sparkles.wired.json.reader : parseJsonDocument;

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
