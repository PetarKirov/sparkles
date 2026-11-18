/// `ci perf`: recording a task's run records, and publishing them to
/// `refs/perf/data`.
module commands.perf;

import cli : GithubOptions, PerfCommand;
import commands.files : detectRepoRoot;
import perf_run : RunRecorder;
import sparkles.base.expected : andThen, Expected, ok;
import sparkles.base.logger : error, info, warning;
import sparkles.core_cli.args : failRun, ranOk, RunError, RunExpected;
import std.conv : text;
import std.path : buildPath;
import std.string : lineSplitter;

/// `ci perf record ID -- COMMAND…`: run the command with this process's
/// standard streams, record it as task `ID` (its wall time and outcome) in a
/// run record, and exit with its status. A record that cannot be written is a
/// warning, never a change of status (observability OBD11).
RunExpected!void runRecordTask(string taskId, string[] command, string placement, string shard)
{
    import std.process : spawnProcess, wait;

    if (command.length == 0)
    return failRun(text(i"ci perf record $(taskId) needs a command after --"), 2);
    const repoRoot = detectRepoRoot();
    auto recorder = RunRecorder.open(repoRoot is null ? "." : repoRoot, "perf record", [taskId],
        placement, shard);
    int status;
    recorder.begin();
    try
        status = wait(spawnProcess(command));
    catch (Exception e)
    {
        error(i"ci perf record $(taskId): $(e.msg)");
        status = 127;
    }
    recorder.end(taskId, status == 0);
    if (const degradation = recorder.finish())
        warning(i"$(degradation)");
    return status == 0 ? ranOk() : failRun(text(taskId, " exited with status ", status), status);
}

/// The repository root and its history's allowed-signers file.
private RunExpected!string perfSigners()
{
    import std.path : buildPath;

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
        return failRun!string("Could not detect repository root");
    return ok!RunError(buildPath(repoRoot, "nix", "perf-data-signers"));
}

/// A publishing step's outcome: its report logged line by line.
private RunExpected!void reportPublished(Expected!(string, string) done)
{
    if (done.hasError)
        return failRun(done.error);
    foreach (line; done.value.lineSplitter)
        info(i"$(line)");
    return ranOk();
}

/// `ci perf import RUN`: records from a GitHub Actions run's job logs.
RunExpected!void runPerfImportCommand(string runId, string repo)
{
    import perf_publish : importGithubRun;

    return reportPublished(importGithubRun(repo, runId));
}

/// `ci perf push`: this machine's records, signed by the maintainer (OBH6).
RunExpected!void runPerfPushCommand(bool allowDirty, string signingKey, string historyRemote)
{
    import perf_publish : configuredSigningKey, pushLocal, pushRemote;

    return perfSigners().andThen!((signers) {
        const key = signingKey.length ? signingKey : configuredSigningKey(detectRepoRoot());
        if (key.length == 0)
            return failRun("ci perf push needs --signing-key or git's user.signingkey", 2);
        return reportPublished(pushLocal(allowDirty, key, historyRemote.length ? historyRemote : pushRemote,
            signers));
    });
}

/// `ci perf append`: a CI run's downloaded records, signed by CI (OBH4).
RunExpected!void runPerfAppendCommand(in PerfCommand.Append cmd)
{
    import perf_history : canonicalRemote;
    import perf_publish : appendRun;

    if (cmd.signing.signingKey.length == 0)
        return failRun("ci perf append needs --signing-key", 2);
    const remote = cmd.history.historyRemote.length ? cmd.history.historyRemote : canonicalRemote;
    return perfSigners().andThen!(signers => appendRunAndPr(cmd, remote, signers));
}

/// The run's records, then, with --repo, the landing's pull request record (OBJ4).
private RunExpected!void appendRunAndPr(in PerfCommand.Append cmd, string remote, string signers)
{
    import ci_stats : fetchAndDeserializeJson;
    import perf_publish : appendRun;
    import perf_pr : appendLandedPr;

    auto runs = reportPublished(appendRun(cmd.records, cmd.runId, cmd.runAttempt, cmd.runDate,
        cmd.landedCommit, cmd.signing.signingKey, remote, signers));
    if (cmd.github.repo.length == 0)
        return runs;
    // Appended whatever became of the run's records: the two are independent.
    auto pr = reportPublished(appendLandedPr!fetchAndDeserializeJson(cmd.github.repo, cmd.landedCommit,
        githubToken(cmd.github), cmd.signing.signingKey, remote, signers));
    return runs.hasError ? runs : pr;
}

/// The token of `github`, or `$GITHUB_TOKEN`.
private string githubToken(const GithubOptions github)
{
    import std.process : environment;

    return github.token.length ? github.token : environment.get("GITHUB_TOKEN", "");
}

/// `ci perf import-prs`: merged pull requests' records, written locally (OBQ9).
RunExpected!void runPerfImportPrsCommand(in GithubOptions github, string since)
{
    import ci_stats : fetchAndDeserializeJson;
    import perf_pr : importPrs;

    return reportPublished(importPrs!fetchAndDeserializeJson(github.repo, since, githubToken(github)));
}

/// `ci perf site`: the dashboard, from the verified history (§17).
RunExpected!void runPerfSiteCommand(in PerfCommand.Site cmd)
{
    import perf_history : canonicalRemote;
    import perf_site : buildSite, loadSite, writeSite;

    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
        return failRun("Could not detect repository root");
    const remote = cmd.history.historyRemote.length ? cmd.history.historyRemote : canonicalRemote;
    const rates = cmd.rates.length ? cmd.rates : buildPath(repoRoot, "ci", "runner-rates.json");
    return perfSigners().andThen!(signers => buildSiteAt(cmd, remote, signers, repoRoot, rates));
}

private RunExpected!void buildSiteAt(in PerfCommand.Site cmd, string remote, string signers, string repoRoot,
    string rates)
{
    import perf_site : buildSite, loadSite, writeSite;

    string report;
    const data = loadSite(remote, signers, cmd.historyTip, repoRoot, rates, report);
    foreach (line; report.lineSplitter)
        warning(i"$(line)");
    const files = buildSite(data);
    writeSite(files, cmd.out_);
    info(i"wrote $(files.length) files to $(cmd.out_): $(data.records.length) pull request record(s) at $(data.tip)");
    return ranOk();
}
