import std.file : exists;
import std.path : buildPath;
import std.stdio : stderr, writeln;

import sparkles.markdown.testing : FixtureCase, loadFixtureJsonl, writeFixtureJsonl;

int main(string[] args)
{
    auto inputPath = args.length > 1
        ? args[1]
        : buildPath("libs", "markdown", "tests", "corpus", "tier_a", "commonmark_seed.jsonl");
    auto outputPath = args.length > 2
        ? args[2]
        : buildPath("libs", "markdown", "tests", "corpus", "generated", "commonmark_spec.jsonl");

    if (!exists(inputPath))
    {
        stderr.writeln("Input fixture file not found: ", inputPath);
        return 2;
    }

    FixtureCase[] fixtures = loadFixtureJsonl(inputPath);
    writeFixtureJsonl(outputPath, fixtures);

    writeln("ingest_commonmark_spec: wrote ", fixtures.length, " fixtures to ", outputPath);
    return 0;
}
