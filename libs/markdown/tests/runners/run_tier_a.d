import std.path : buildPath;
import std.stdio : writeln;

import sparkles.markdown : Profile;
import sparkles.markdown.testing :
    FixtureRunOptions,
    isSuitePassing,
    runFixtureSuite,
    summaryToMarkdown;

int main()
{
    auto options = FixtureRunOptions(
        tierName: "tier-a",
        fixturePaths: [
            buildPath("libs", "markdown", "tests", "corpus", "tier_a", "commonmark_seed.jsonl"),
            buildPath("libs", "markdown", "tests", "corpus", "generated", "commonmark_spec.jsonl"),
        ],
        hasProfileFilter: true,
        profileFilter: Profile.commonmark_strict,
        summaryJsonPath: buildPath("libs", "markdown", "tests", "corpus", "generated", "summary_tier_a.json"),
    );

    auto summary = runFixtureSuite(options);
    writeln(summaryToMarkdown(summary));

    return isSuitePassing(summary) ? 0 : 1;
}
