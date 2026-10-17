import std.algorithm.sorting : sort;
import std.datetime.systime : Clock;
import std.file : mkdirRecurse, readText, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : writeln;

import sparkles.markdown.testing : FixtureCase, loadFixtureJsonl, validateUniqueIds, writeFixtureJsonl;

int main()
{
    auto corpusRoot = buildPath("libs", "markdown", "tests", "corpus");
    auto generatedDir = buildPath(corpusRoot, "generated");
    auto outputPath = buildPath(generatedDir, "fixtures.jsonl");
    auto manifestPath = buildPath(generatedDir, "manifest.json");

    FixtureCase[] fixtures;
    fixtures ~= loadFixtureJsonl(buildPath(corpusRoot, "tier_a", "commonmark_seed.jsonl"));
    fixtures ~= loadFixtureJsonl(buildPath(corpusRoot, "tier_b", "compat_seed.jsonl"));
    fixtures ~= loadFixtureJsonl(buildPath(corpusRoot, "tier_d", "pathological_seed.jsonl"));

    fixtures.sort!((a, b) => a.id < b.id);

    string[] duplicates;
    if (!validateUniqueIds(fixtures, duplicates))
    {
        writeln("ingest_all: duplicate fixture IDs detected");
        foreach (id; duplicates)
            writeln("  - ", id);
        return 2;
    }

    writeFixtureJsonl(outputPath, fixtures);

    JSONValue manifest;
    auto existingManifest = parseJSON(readText(manifestPath));
    manifest.object = existingManifest.object;
    manifest.object["schemaVersion"] = 1;
    manifest.object["generatedAt"] = Clock.currTime.toISOExtString();
    manifest.object["sourcePinsFile"] = "../sources.json";
    manifest.object["flakeLockPath"] = "../flake.lock";
    manifest.object["fixtureCount"] = cast(long) fixtures.length;

    JSONValue ids;
    ids.array = [];
    foreach (fixture; fixtures)
        ids.array ~= JSONValue(fixture.id);
    manifest.object["fixtures"] = ids;

    mkdirRecurse(generatedDir);
    write(manifestPath, manifest.toString ~ "\n");

    writeln("ingest_all: wrote ", fixtures.length, " fixtures to ", outputPath);
    return 0;
}
