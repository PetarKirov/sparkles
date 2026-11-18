/// `ci stats`: run statistics and the merge audit. The pure statistics are
/// `ci_stats.d`'s.
module commands.stats;

import cli : StatsCommand;
import sparkles.base.logger : error, info;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;
import std.array : split;
import std.conv : text, to;
import std.process : environment;
import std.stdio : writeln;

RunExpected!void runCiStatsCommand(in StatsCommand cli)
{
    import std.process : environment;
    import std.stdio : writeln;

    import ci_stats : CiStatsOptions, fetchAndDeserializeJson, runCiStats;

    string token = cli.github.token;
    if (token.length == 0)
        token = environment.get("GITHUB_TOKEN", "");

    // `--merges` audits what landed on the branch rather than how long jobs
    // took: a different question over a different endpoint, sharing only the
    // repo/token/limit options.
    if (cli.merges)
        return runMergeAudit(cli.github.repo, token, cli.limit, cli.badgeDir);

    auto opts = CiStatsOptions(
        repo: cli.github.repo,
        token: token,
        limit: cli.limit,
        since: cli.since,
        workflowFilter: cli.workflow,
        conclusionFilter: cli.conclusion,
        branchFilter: cli.branch,
        baselineBranch: cli.baseline,
        splitAt: cli.split,
        showSteps: cli.steps,
        stepJobs: cli.stepJobs,
    );

    auto res = runCiStats!fetchAndDeserializeJson(opts);
    if (res.hasError)
    {
        import sparkles.base.logger : error;
        string errMsg = res.error;
        return failRun(text(i"ci-stats failed: $(errMsg)"));
    }

    return ranOk();
}

/// `ci stats --merges`: what landed on the default branch, and what it would
/// cost to verify the part the pull requests did not already prove.
private RunExpected!void runMergeAudit(string repo, string token, int limit, string badgeDir)
{
    import sparkles.base.logger : error, info;

    import ci_stats : fetchAndDeserializeJson;
    import merge_audit : auditMerges, fetchMergedPrs, renderMergeAudit, writeBadges;

    if (repo.length == 0)
    return failRun("--merges needs --repo owner/repo");

    auto prs = fetchMergedPrs!fetchAndDeserializeJson(repo, token, limit);
    if (prs.hasError)
    {
        string errMsg = prs.error;
        return failRun(text(i"merge audit failed: $(errMsg)"));
    }

    const audit = auditMerges(prs.value);
    renderMergeAudit(prs.value, audit);

    // The badge is written from the same aggregate the table renders, so the
    // number in the README can never disagree with the number here.
    if (badgeDir.length)
    {
        writeBadges(audit, badgeDir);
        info(i"wrote badge endpoints to $(badgeDir)");
    }

    return ranOk();
}
