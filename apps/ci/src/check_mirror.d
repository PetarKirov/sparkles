/++
`ci --mirror-checks` — give a commit on the default branch the checks its pull
request already earned.

The repository merges by rebase, so nothing that lands on `main` carries a SHA
any CI run has seen. Re-running the whole matrix per merge would buy a green
tick at the price of a second full build; running nothing leaves the branch tip
bare, and whichever cheap job does run on `main` becomes the entire public
impression of the project.

There is a third option, and it is exact rather than approximate. A rebase that
only changes parentage leaves the **tree** untouched, and a commit's tree is
the whole of what a build sees. So when the landed tree equals the tree the
pull request built, that pull request's checks are not an approximation of this
commit's result — they are a report about this exact content, filed against a
different SHA. Copying them across claims nothing that was not tested.

When the trees differ the base moved under the pull request, the merge produced
content no run has ever built, and there is nothing honest to copy. This
command says so and exits; the caller runs the real thing.

`ci --ci-stats --merges` measures the split over history — 75.7% mirrorable
against 24.3% needing a build, at the time this was written.

$(B Token:) creating a check run is an app-authenticated call. A workflow's
`GITHUB_TOKEN` with `checks: write` is such a token; a personal access token is
not, and gets a 403 no matter its scopes. Use `--dry-run` to exercise the
decision path from a terminal.
+/
module check_mirror;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind;
import std.array : array;
import std.conv : to;
import std.range.primitives : empty;
import std.typecons : Nullable;

import sparkles.base.logger : error, info, warning;

import sparkles.wired : fromJSON, WireName, WireOptional;

import ci_stats : failure, Result, success;
import merge_audit : RepoRef, splitRepo;

// ---------------------------------------------------------------------------
// Response models
// ---------------------------------------------------------------------------

private struct GhTreeRef
{
    string sha;
}

private struct GhCommitBody
{
    GhTreeRef tree;
}

private struct GhCommit
{
    string sha;
    GhCommitBody commit;
}

private struct GhPullRef
{
    int number;
    string state;
    // The list endpoint reports the merge as a timestamp, not the `merged`
    // boolean the single-pull-request endpoint carries.
    @WireOptional() Nullable!string merged_at;
    @WireName("html_url") string htmlUrl;
    GhBranchRef head;
}

private struct GhBranchRef
{
    string sha;
}

private struct GhCheckRun
{
    string name;
    string status;
    Nullable!string conclusion;
    @WireOptional() Nullable!string details_url;
    @WireOptional() Nullable!string started_at;
    @WireOptional() Nullable!string completed_at;
    // Absent for a check run created straight through the API rather than by a
    // workflow — a mirrored one, for instance.
    @WireOptional() Nullable!GhCheckApp app;
}

private struct GhCheckApp
{
    string slug;
}

private struct GhCheckRunsResponse
{
    long total_count;
    @WireName("check_runs") GhCheckRun[] checkRuns;
}

private struct GhCreatedCheckRun
{
    long id;
}

// ---------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------

/// What `--mirror-checks` decided, and why. The caller (a workflow) branches on
/// `mirrored`: false means "build this commit for real".
struct MirrorOutcome
{
    bool mirrored;
    /// The pull request the commit came from, or 0 when none was found.
    int pullRequest;
    /// How many check runs were copied across.
    size_t copied;
    /// One line, suitable for a workflow log and a step summary.
    string reason;
}

/// Check runs worth copying. A check that never completed says nothing about
/// the commit, and a workflow that runs on the push itself will file its own
/// result — mirroring it would leave the commit carrying two checks of the
/// same name, one of them stale before it was written.
bool shouldMirror(in GhCheckRun run, in string[] skipNames) @safe pure
{
    if (run.status != "completed")
        return false;
    if (run.conclusion.isNull)
        return false;
    return !skipNames.canFind(run.name);
}

@("check_mirror.shouldMirror.onlyCompletedAndNotExcluded")
@safe pure unittest
{
    static GhCheckRun done(string name, string conclusion)
    {
        GhCheckRun r;
        r.name = name;
        r.status = "completed";
        r.conclusion = conclusion;
        return r;
    }

    assert(shouldMirror(done("test", "success"), null));
    // A red pull request mirrors red: the point is an accurate branch tip, not
    // a green one.
    assert(shouldMirror(done("test", "failure"), null));
    assert(!shouldMirror(done("deploy", "success"), ["deploy"]));

    GhCheckRun running;
    running.name = "test";
    running.status = "in_progress";
    assert(!shouldMirror(running, null));
}

/// The body of the mirrored check run. Keeping it a pure function of the
/// original makes the provenance line testable, which matters: it is the only
/// place a reader learns these checks were filed against another SHA.
string mirroredCheckBody(
    const GhCheckRun run, string headSha, string sha, int pullRequest, string treeSha,
) @safe
{
    import std.json : JSONValue;

    JSONValue output;
    output["title"] = "Mirrored from #" ~ pullRequest.to!string;
    output["summary"] =
        "This commit's tree (`" ~ treeSha[0 .. 7] ~ "`) is identical to the tree "
        ~ "built for [#" ~ pullRequest.to!string ~ "](../pull/" ~ pullRequest.to!string
        ~ ") at `" ~ headSha[0 .. 7] ~ "`, so that run's `" ~ run.name
        ~ "` result describes this content exactly. Rebasing changed the commit's "
        ~ "parent, not what was built.\n\nNothing was re-run; follow the details "
        ~ "link for the original job.";

    JSONValue root;
    root["name"] = run.name;
    root["head_sha"] = sha;
    root["status"] = "completed";
    root["conclusion"] = run.conclusion.get;
    root["output"] = output;
    if (!run.details_url.isNull && run.details_url.get.length)
        root["details_url"] = run.details_url.get;
    if (!run.started_at.isNull && run.started_at.get.length)
        root["started_at"] = run.started_at.get;
    if (!run.completed_at.isNull && run.completed_at.get.length)
        root["completed_at"] = run.completed_at.get;
    return root.toString;
}

@("check_mirror.mirroredCheckBody.carriesConclusionAndProvenance")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import std.json : parseJSON;

    GhCheckRun run;
    run.name = "test (ubuntu-latest)";
    run.status = "completed";
    run.conclusion = "success";
    run.details_url = "https://example.invalid/job/1";

    auto j = parseJSON(mirroredCheckBody(run, "a".repeat7, "b".repeat7, 411, "c".repeat7));
    assert(j["name"].str == "test (ubuntu-latest)");
    assert(j["conclusion"].str == "success");
    assert(j["head_sha"].str == "b".repeat7);
    assert(j["details_url"].str == "https://example.invalid/job/1");
    assert(j["output"]["title"].str == "Mirrored from #411");
    // The summary must name the pull request: a check with no provenance is
    // indistinguishable from one this commit earned itself.
    assert(j["output"]["summary"].str.canFind("#411"));
}

version (unittest)
private string repeat7(string c) @safe
{
    import std.array : replicate;

    return c.replicate(7);
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

/// Mirror the checks of the pull request that produced `sha` onto `sha`, when
/// and only when the trees agree.
///
/// Templated on the fetcher so the whole decision path is exercisable without
/// a network.
Result!MirrorOutcome mirrorChecks(alias fetchJson)(
    string repo, string token, string sha, in string[] skipNames, bool dryRun,
)
{
    auto parts = splitRepo(repo);
    if (parts.hasError)
        return failure!MirrorOutcome(parts.error);

    string[string] headers;
    if (token.length)
        headers["Authorization"] = "Bearer " ~ token;

    const api = "https://api.github.com/repos/" ~ repo;

    // The pull requests a commit belongs to. GitHub keeps this association
    // across a rebase merge, which is what makes the whole approach possible.
    auto pulls = fetchJson!(GhPullRef[])(api ~ "/commits/" ~ sha ~ "/pulls", "GET", null, headers);
    if (pulls.hasError)
        return failure!MirrorOutcome(pulls.error);

    auto merged = pulls.value.filter!(p => !p.merged_at.isNull && p.merged_at.get.length).array;
    if (merged.empty)
        return success(MirrorOutcome(reason:
            "no merged pull request is associated with " ~ sha[0 .. 7]));

    const pr = merged[0];

    auto landed = fetchJson!GhCommit(api ~ "/commits/" ~ sha, "GET", null, headers);
    if (landed.hasError)
        return failure!MirrorOutcome(landed.error);

    auto tested = fetchJson!GhCommit(api ~ "/commits/" ~ pr.head.sha, "GET", null, headers);
    if (tested.hasError)
        return failure!MirrorOutcome(tested.error);

    const landedTree = landed.value.commit.tree.sha;
    const testedTree = tested.value.commit.tree.sha;
    if (landedTree != testedTree)
        return success(MirrorOutcome(pullRequest: pr.number, reason:
            "#" ~ pr.number.to!string ~ " built tree " ~ testedTree[0 .. 7]
            ~ " but " ~ sha[0 .. 7] ~ " carries " ~ landedTree[0 .. 7]
            ~ " — the base moved, so this content was never built"));

    // What the commit already carries. A check name it has is a name this must
    // not add: filing a second one leaves two results of the same name on one
    // commit, and a reader has no way to tell which is current.
    //
    // Two things make that reachable rather than theoretical. Running this
    // twice over the same commit is one — `main-checks.yml` exposes a manual
    // trigger, so it is a button someone can press. A merge queue is the other:
    // the queue tests the very commit it fast-forwards onto the branch, so that
    // commit arrives already holding its own real results, and mirroring the
    // pull request's on top would bury them under copies. Skipping names that
    // are present makes the command idempotent and merge-queue-safe at once.
    auto existing = fetchJson!GhCheckRunsResponse(
        api ~ "/commits/" ~ sha ~ "/check-runs?per_page=100", "GET", null, headers);
    if (existing.hasError)
        return failure!MirrorOutcome(existing.error);

    auto present = skipNames.dup ~ existing.value.checkRuns.map!(r => r.name).array;

    auto runs = fetchJson!GhCheckRunsResponse(
        api ~ "/commits/" ~ pr.head.sha ~ "/check-runs?per_page=100", "GET", null, headers);
    if (runs.hasError)
        return failure!MirrorOutcome(runs.error);

    auto mirrorable = runs.value.checkRuns.filter!(r => shouldMirror(r, present)).array;
    // Nothing left to copy is a *success* when the commit already had the
    // checks: `mirrored: true` says the commit is described, however it got
    // that way, and it is what stops the caller rebuilding a commit that a
    // merge queue has already built.
    if (mirrorable.empty)
    {
        const covered = existing.value.checkRuns.length > 0;
        return success(MirrorOutcome(
            mirrored: covered,
            pullRequest: pr.number,
            reason: covered
                ? sha[0 .. 7] ~ " already carries " ~ existing.value.checkRuns.length.to!string
                    ~ " checks of its own; nothing to add from #" ~ pr.number.to!string
                : "#" ~ pr.number.to!string ~ " has no completed check runs to mirror",
        ));
    }

    size_t copied;
    foreach (run; mirrorable)
    {
        const body_ = mirroredCheckBody(run, pr.head.sha, sha, pr.number, landedTree);
        if (dryRun)
        {
            string name = run.name;
            string conclusion = run.conclusion.get;
            info(i"would mirror $(name) [$(conclusion)]");
            ++copied;
            continue;
        }

        auto created = fetchJson!GhCreatedCheckRun(api ~ "/check-runs", "POST", body_, headers);
        if (created.hasError)
        {
            // One rejected check run is not a reason to abandon the rest: a
            // partial mirror still describes the commit better than none.
            string name = run.name;
            string why = created.error;
            warning(i"could not mirror $(name): $(why)");
            continue;
        }
        ++copied;
    }

    return success(MirrorOutcome(
        mirrored: copied > 0,
        pullRequest: pr.number,
        copied: copied,
        reason: "#" ~ pr.number.to!string ~ " built the same tree ("
            ~ landedTree[0 .. 7] ~ "); mirrored " ~ copied.to!string ~ " checks",
    ));
}

@("check_mirror.mirrorChecks.rejectsMalformedRepo")
@system unittest
{
    // `static`: DMD rejects a nested function template as an alias parameter
    // ("`never` is a nested function and cannot be accessed from ..."), because
    // the instantiation would need a context pointer. LDC accepts it, so this
    // only shows up on the dmd leg of the matrix.
    static auto never(T)(string, string = "GET", string = null, string[string] = null)
        => failure!T("the fetcher must not be reached");
    auto res = mirrorChecks!never("sparkles", "", "deadbeef", null, true);
    assert(res.hasError);
}

/// Append the outcome to `$GITHUB_OUTPUT` so a workflow can branch on it, and
/// to `$GITHUB_STEP_SUMMARY` so a person can read why. Both are no-ops off CI.
void publishOutcome(in MirrorOutcome outcome)
{
    import std.process : environment;
    import std.stdio : File;

    void appendTo(string var, string text)
    {
        const path = environment.get(var, "");
        if (path.length == 0)
            return;
        try
            File(path, "a").write(text);
        catch (Exception e)
        {
            string why = e.msg;
            warning(i"could not write $(var): $(why)");
        }
    }

    appendTo("GITHUB_OUTPUT", "mirrored=" ~ (outcome.mirrored ? "true" : "false") ~ "\n");
    appendTo("GITHUB_STEP_SUMMARY",
        (outcome.mirrored ? "### Checks mirrored\n\n" : "### Nothing to mirror\n\n")
        ~ outcome.reason ~ "\n");
}

@("check_mirror.mirrorChecks.doesNotRefileChecksTheCommitAlreadyHas")
@system unittest
{
    // The commit and the pull request head share a tree, and the commit already
    // carries `CI` — the shape a re-run produces, and the shape a merge queue
    // produces. Nothing may be POSTed.
    static auto fetch(T)(string url, string method = "GET", string = null, string[string] = null)
    {
        import std.algorithm.searching : canFind, endsWith;

        assert(method == "GET", "an already-covered commit must not be written to");

        static if (is(T == GhPullRef[]))
        {
            GhPullRef pr;
            pr.number = 7;
            pr.merged_at = "2026-08-28T00:00:00Z";
            pr.head = GhBranchRef("head000");
            return success([pr]);
        }
        else static if (is(T == GhCommit))
            // Both commits report the same tree, so the mirror is allowed and
            // only the already-present check stops it.
            return success(GhCommit("sha0000", GhCommitBody(GhTreeRef("tree000"))));
        else static if (is(T == GhCheckRunsResponse))
        {
            GhCheckRun run;
            run.name = "CI";
            run.status = "completed";
            run.conclusion = "success";
            return success(GhCheckRunsResponse(1, [run]));
        }
        else
            return failure!T("unexpected request: " ~ url);
    }

    auto res = mirrorChecks!fetch("o/r", "t", "sha0000deadbeef", null, false);
    assert(!res.hasError);
    // Covered, so the caller must not rebuild — but nothing was filed.
    assert(res.value.mirrored);
    assert(res.value.copied == 0);
}
