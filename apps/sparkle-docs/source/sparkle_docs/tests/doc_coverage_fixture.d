module sparkle_docs.tests.doc_coverage_fixture;

version (unittest)
{
import std.algorithm : canFind, map, sort, uniq;
import std.array : array;
import std.file : exists, mkdirRecurse, readText;
import std.json : JSONOptions;
import std.path : buildPath;
import std.string : indexOf;

import sparkles.core_cli.json : readJsonFile, toJSON;
import sparkles.test_utils.tmpfs : TmpFS;

import sparkle_docs.model : Output, Symbol, Config;
import sparkle_docs.output : OutputGenerator;
import sparkle_docs.parser.dmd_json : DmdJsonParser;

struct SearchEntry
{
    string qualifiedName;
    string name;
    string kind;
    string summary;
    string url;
}

struct SearchData
{
    SearchEntry[] index;
}

private string fixtureRoot()
{
    string[] candidates = [
        "apps/doc-coverage-fixture",
        "../doc-coverage-fixture",
        "../../apps/doc-coverage-fixture",
    ];
    foreach (candidate; candidates)
    {
        if (candidate.exists)
            return candidate;
    }
    assert(0, "Could not locate apps/doc-coverage-fixture");
    return "";
}

private string docsFixtureRoot()
{
    return "apps/sparkle-docs/test/data/doc_coverage";
}

private string normalizeIndexJson(string path)
{
    auto output = readJsonFile!Output(path);
    output.generated = "__GEN__";
    return output.toJSON.toPrettyString(JSONOptions.doNotEscapeSlashes);
}

private void assertFileEqual(string actualPath, string expectedPath)
{
    auto actual = readText(actualPath);
    auto expected = readText(expectedPath);
    if (actual != expected)
    {
        assert(0, "Snapshot mismatch for '" ~ actualPath ~ "' vs '" ~ expectedPath ~ "'");
    }
}

private Output loadIndexOutput(string outputDir)
{
    return readJsonFile!Output(buildPath(outputDir, "index.json"));
}

private int generateDocs(string[] sourcePaths, string[] excludes, bool includePrivate,
        string outDir, bool compact = false)
{
    auto parser = DmdJsonParser(sourcePaths, excludes, includePrivate);
    auto output = parser.parse();
    auto generator = OutputGenerator(outDir, compact);
    generator.generate(output);
    return 0;
}

private SearchData loadSearchOutput(string outputDir)
{
    return readJsonFile!SearchData(buildPath(outputDir, "search.json"));
}

private bool hasSymbol(Output output, string qualifiedName)
{
    bool walk(Symbol[] symbols)
    {
        foreach (symbol; symbols)
        {
            if (symbol.qualifiedName == qualifiedName)
                return true;
            if (walk(symbol.members))
                return true;
        }
        return false;
    }

    foreach (_moduleName, mod; output.modules)
    {
        if (walk(mod.symbols))
            return true;
    }
    return false;
}

@("sparkleDocs.fixture.positionalAndGolden")
@system
unittest
{
    auto tmpfs = TmpFS.create("sparkle-docs-fixture-positional");
    const outDir = buildPath(tmpfs.dir, "out");
    mkdirRecurse(outDir);

    const sourceRoot = buildPath(fixtureRoot(), "source");
    auto rc = generateDocs([sourceRoot], ["*broken*"], false, outDir);
    assert(rc == 0);

    auto output = loadIndexOutput(outDir);
    auto search = loadSearchOutput(outDir);

    assert(output.modules.length > 5);
    assert(search.index.length > 20);

    auto kinds = search.index
        .map!(entry => entry.kind)
        .array
        .sort
        .uniq
        .array;

    foreach (expectedKind; [
        "struct", "class", "interface", "enum", "function", "variable", "alias",
        "template", "constructor", "destructor", "enumMember",
    ])
        assert(kinds.canFind(expectedKind), "Missing kind in search index: " ~ expectedKind);

    foreach (entry; search.index)
    {
        assert(entry.url.indexOf(".html") < 0, "Found .html URL: " ~ entry.url);
        assert(entry.url.indexOf("/api/") == 0, "Unexpected URL prefix: " ~ entry.url);
    }

    assert(hasSymbol(output, "doc_coverage.core.commands.MoveCommand"));

    auto commandsModulePath = buildPath(outDir, "doc_coverage_core_commands.json");
    auto commandsJson = commandsModulePath.readText;
    assert(commandsJson.indexOf("\"examples\": [") >= 0);
    assert(commandsJson.indexOf("\"unittests\": [") >= 0);

    const goldenRoot = buildPath(docsFixtureRoot(), "golden");
    assertFileEqual(buildPath(outDir, "search.json"), buildPath(goldenRoot, "search.json"));
    assertFileEqual(commandsModulePath, buildPath(goldenRoot, "doc_coverage_core_commands.json"));
    assertFileEqual(buildPath(outDir, "doc_coverage_mixed_templates.json"),
        buildPath(goldenRoot, "doc_coverage_mixed_templates.json"));
    assertFileEqual(buildPath(outDir, "doc_coverage_game_entities.json"),
        buildPath(goldenRoot, "doc_coverage_game_entities.json"));

    auto normalizedIndex = normalizeIndexJson(buildPath(outDir, "index.json"));
    auto expectedNormalizedIndex = readText(buildPath(goldenRoot, "index.normalized.json"));
    if (normalizedIndex != expectedNormalizedIndex)
    {
        assert(0, "Normalized index snapshot mismatch");
    }
}

@("sparkleDocs.fixture.configInvocation")
@system
unittest
{
    auto tmpfs = TmpFS.create("sparkle-docs-fixture-config");
    const outDir = buildPath(tmpfs.dir, "out");
    mkdirRecurse(outDir);

    auto cfg = readJsonFile!Config(buildPath(fixtureRoot(), "sparkle-docs.json"));
    auto rc = generateDocs(cfg.sourcePaths, cfg.excludePatterns, cfg.includePrivate, outDir);
    assert(rc == 0);

    auto output = loadIndexOutput(outDir);

    assert(!output.modules.keys.canFind("doc_coverage.internal.private_bits"));
    assert(!output.modules.keys.canFind("doc_coverage.broken.missing_import_case"));
}

@("sparkleDocs.fixture.excludeAndIncludePrivate")
@system
unittest
{
    auto tmpfs = TmpFS.create("sparkle-docs-fixture-privacy");

    const noPrivateOut = buildPath(tmpfs.dir, "no-private");
    mkdirRecurse(noPrivateOut);
    auto rcNoPrivate = generateDocs(
        [buildPath(fixtureRoot(), "source")],
        ["*broken*", "*internal*"],
        false,
        noPrivateOut
    );
    assert(rcNoPrivate == 0);
    auto noPrivate = loadIndexOutput(noPrivateOut);
    assert(!hasSymbol(noPrivate, "doc_coverage.core.commands.privateCommandCount"));

    const withPrivateOut = buildPath(tmpfs.dir, "with-private");
    mkdirRecurse(withPrivateOut);
    auto rcWithPrivate = generateDocs(
        [buildPath(fixtureRoot(), "source")],
        ["*broken*"],
        true,
        withPrivateOut
    );
    assert(rcWithPrivate == 0);

    auto withPrivate = loadIndexOutput(withPrivateOut);
    assert(hasSymbol(withPrivate, "doc_coverage.core.commands.privateCommandCount"));
    assert(hasSymbol(withPrivate, "doc_coverage.internal.private_bits.hiddenIncrement"));
}

@("sparkleDocs.fixture.failFast")
@system
unittest
{
    auto parser = DmdJsonParser([
        buildPath(fixtureRoot(), "source", "doc_coverage", "broken", "missing_import_case.d")
    ]);

    bool failed;
    try
    {
        parser.parse();
    }
    catch (Exception e)
    {
        failed = true;
        assert(e.msg.indexOf("missing_import_case.d") >= 0);
        assert(e.msg.indexOf("dmd -X failed") >= 0);
    }

    assert(failed, "Expected fail-fast parse error for broken fixture module");
}

@("sparkleDocs.fixture.compactOutput")
@system
unittest
{
    auto tmpfs = TmpFS.create("sparkle-docs-fixture-compact");
    const outDir = buildPath(tmpfs.dir, "compact");
    mkdirRecurse(outDir);

    auto rc = generateDocs(
        [buildPath(fixtureRoot(), "source")],
        ["*broken*"],
        false,
        outDir,
        true
    );
    assert(rc == 0);

    auto searchTxt = readText(buildPath(outDir, "search.json"));
    assert(searchTxt.length > 0);
    assert(searchTxt.indexOf("\n") < 0, "Compact output should not contain newlines");
}
}
