/// `ci github`: mirroring a pull request's checks onto its landed commit, and
/// reconciling the link-rot issue.
module commands.github;

import cli : GithubOptions;
import sparkles.base.logger : error, info;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;
import std.conv : text;
import std.file : exists, readText;
import std.process : environment;

/// `ci github mirror-checks`: attach a pull request's checks to the commit its work
/// landed as, when the landed tree is the tree that pull request built.
RunExpected!void runMirrorChecksCommand(in GithubOptions github, string sha, in string[] skipCheck,
    bool dryRun)
{
    import std.process : environment;

    import sparkles.base.logger : error, info;

    import check_mirror : mirrorChecks, publishOutcome;
    import ci_stats : fetchAndDeserializeJson;

    string token = github.token;
    if (token.length == 0)
        token = environment.get("GITHUB_TOKEN", "");

    auto res = mirrorChecks!fetchAndDeserializeJson(
        github.repo, token, sha, skipCheck, dryRun);
    if (res.hasError)
    {
        string errMsg = res.error;
        return failRun(text(i"mirror-checks failed: $(errMsg)"));
    }

    const outcome = res.value;
    string reason = outcome.reason;
    info(i"$(reason)");
    publishOutcome(outcome);

    // Not mirroring is a routine answer, not a failure: the caller reads
    // `mirrored` and builds the commit for real.
    return ranOk();
}

/// `ci github link-rot-issue`: reconcile the standing link-rot issue with the sweep's
/// verdict, so its presence means "links are broken" and nothing else does.
RunExpected!void runReportLinkRotCommand(in GithubOptions github, string reportPath, bool rotten,
    string runUrl)
{
    import std.file : exists, readText;
    import std.process : environment;

    import sparkles.base.logger : error, info;

    import ci_stats : fetchAndDeserializeJson;
    import link_rot : reportLinkRot;

    string token = github.token;
    if (token.length == 0)
        token = environment.get("GITHUB_TOKEN", "");

    string report;
    if (reportPath.length && reportPath.exists)
        report = reportPath.readText;

    auto res = reportLinkRot!fetchAndDeserializeJson(
        github.repo, token, rotten, report, runUrl);
    if (res.hasError)
    {
        string errMsg = res.error;
        return failRun(text(i"report-link-rot failed: $(errMsg)"));
    }

    string action = res.value.action;
    info(i"$(action)");
    return ranOk();
}
