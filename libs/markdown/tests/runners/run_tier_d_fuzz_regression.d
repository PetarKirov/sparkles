import core.time : dur;

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
        tierName: "tier-d",
        fixturePaths: [
            buildPath("libs", "markdown", "tests", "corpus", "tier_d", "pathological_seed.jsonl"),
        ],
        includeSlow: true,
        perFixtureTimeout: dur!"msecs"(100),
        summaryJsonPath: buildPath("libs", "markdown", "tests", "corpus", "generated", "summary_tier_d.json"),
    );

    auto summary = runFixtureSuite(options);
    writeln(summaryToMarkdown(summary));

    return isSuitePassing(summary) ? 0 : 1;
}
