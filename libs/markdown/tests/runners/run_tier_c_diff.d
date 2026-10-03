import std.algorithm.searching : canFind;
import std.file : write;
import std.json : JSONValue;
import std.path : buildPath;
import std.stdio : writeln;

import sparkles.markdown : MarkdownOptions, ParseResult, Profile, RenderOptions, parse, toHtml;
import sparkles.markdown.testing : FixtureCase, canonicalizeHtml, loadFixtureJsonl;

int main(string[] args)
{
    auto strictMode = args.canFind("--strict");

    auto fixturesPath = buildPath("libs", "markdown", "tests", "corpus", "tier_a", "commonmark_seed.jsonl");
    auto summaryPath = buildPath("libs", "markdown", "tests", "corpus", "generated", "summary_tier_c.json");

    FixtureCase[] fixtures = loadFixtureJsonl(fixturesPath);

    string[] divergences;
    foreach (fixture; fixtures)
    {
        auto strictResult = renderWithProfile(fixture.markdown, Profile.commonmark_strict);
        auto gfmResult = renderWithProfile(fixture.markdown, Profile.gfm);

        if (canonicalizeHtml(strictResult) != canonicalizeHtml(gfmResult))
            divergences ~= fixture.id;
    }

    JSONValue summary;
    JSONValue[string] summaryObject;
    summary.object = summaryObject;
    summary.object["tier"] = "tier-c";
    summary.object["fixtureCount"] = cast(long) fixtures.length;
    summary.object["divergenceCount"] = cast(long) divergences.length;

    JSONValue list;
    list.array = [];
    foreach (id; divergences)
        list.array ~= JSONValue(id);
    summary.object["divergences"] = list;

    write(summaryPath, summary.toString ~ "\n");

    writeln("## Tier C Differential Summary");
    writeln;
    writeln("- Fixture count: ", fixtures.length);
    writeln("- Divergence count: ", divergences.length);

    foreach (id; divergences)
        writeln("- ", id);

    if (strictMode && divergences.length > 0)
        return 1;

    return 0;
}

private string renderWithProfile(string markdown, Profile profile)
{
    auto opts = MarkdownOptions!void(profile: profile);
    ParseResult result = parse(markdown, opts);
    return result.toHtml(RenderOptions());
}
