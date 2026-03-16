import std.path : buildPath;
import std.stdio : writeln;

import sparkles.markdown.testing :
    FixtureRunOptions,
    isSuitePassing,
    runFixtureSuite,
    summaryToMarkdown;

int main()
{
    auto options = FixtureRunOptions(
        tierName: "tier-b",
        fixturePaths: [
            buildPath("libs", "markdown", "tests", "corpus", "tier_b", "compat_seed.jsonl"),
        ],
        summaryJsonPath: buildPath("libs", "markdown", "tests", "corpus", "generated", "summary_tier_b.json"),
    );

    auto summary = runFixtureSuite(options);
    writeln(summaryToMarkdown(summary));

    return isSuitePassing(summary) ? 0 : 1;
}
