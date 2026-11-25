/++
Pull request records (observability OBJ4–OBJ6): what each landed pull
request's CI ran, on which runner type, and when, built from the provider's
API and appended to `refs/perf/data` under `prs/<yyyy>/<mm>/<number>/pr.json`.

The record holds facts only. Everything the dashboard shows is derived from
it when read ($(LREF figuresOf), OBJ5), so a new view needs no new record.
+/
module perf_pr;

import cache_home : cacheHome;
import std.algorithm.iteration : filter, map, sum, uniq;
import std.algorithm.searching : any, canFind, maxElement, minElement, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.format : format;
import std.typecons : Nullable;

import sparkles.base.expected : Expected, err, ok;
import sparkles.wired : fromJSON, toJSON, WireName, WireOptional;

import ci_stats : GhStep, makeAuthHeaders, normalizeRunnerKey, Result;
import perf_record : privacyRejection, Producer;

/// The schema name of a pull request record (OBD6).
enum prSchema = "sparkles.perf.pr";
/// Its version.
enum prVersion = 1;

/**
The runner types a record names (OBP3). A label outside the list is recorded
as `<label>`, so a self-hosted runner's machine name never reaches the history.
*/
immutable string[] runnerAllowlist = [
    "macos-13", "macos-14", "macos-15", "macos-latest",
    "ubuntu-22.04", "ubuntu-22.04-arm", "ubuntu-24.04", "ubuntu-24.04-arm", "ubuntu-latest",
    "windows-2022", "windows-2025", "windows-latest",
];

/// The runner type a job's labels name, through the allowlist (OBJ6).
string runnerType(scope const(string)[] labels) @safe pure nothrow
{
    const key = normalizeRunnerKey(labels);
    return runnerAllowlist.canFind(key) ? key : "<label>";
}

@("perfPr.runnerType.allowlist")
@safe pure nothrow unittest
{
    assert(runnerType(["ubuntu-latest"]) == "ubuntu-latest");
    assert(runnerType(["ubuntu-24.04-arm"]) == "ubuntu-24.04-arm");
    assert(runnerType(["self-hosted", "pc1-runner"]) == "<label>", "a machine name never reaches the record");
    assert(runnerType([]) == "<label>");
}

// === The record ===

/// One step of a job, with its instants in Unix seconds.
struct PrStep
{
    string name;
    long start;
    long end;
}

/// One execution of a job. A job that never started has zeros for its instants.
struct PrJob
{
    string name;
    string runner;     /// the runner type (OBJ6)
    uint attempt;      /// the attempt that ran it
    string conclusion; /// `success`, `failure`, `cancelled`, `skipped`, …
    long created;
    long start;
    long end;
    @WireOptional() PrStep[] steps;

    /// Whether it ran: both instants are known and in order.
    bool ran() const @safe pure nothrow @nogc => start > 0 && end >= start;
    /// Its wall time in seconds, zero when it did not run.
    long wall() const @safe pure nothrow @nogc => ran ? end - start : 0;
    /// Its wait for a runner in seconds, never negative.
    long queue() const @safe pure nothrow @nogc => ran && start > created && created > 0 ? start - created : 0;
}

/// One workflow run the pull request caused, every attempt's executions in it.
struct PrRun
{
    long id;
    string workflow; /// the workflow file, `.github/workflows/ci.yml`
    string event;
    string head;     /// the commit it ran on
    long created;
    uint attempts;
    PrJob[] jobs;
}

/// The record of one landed pull request (OBJ4).
struct PrRecord
{
    string schema = prSchema;
    @WireName("version") uint version_ = prVersion;
    long number;
    long created;
    long merged;
    string head;   /// its last head commit
    string landed; /// the commit of `main` it landed as
    @WireOptional() string[] paths;
    @WireOptional() PrRun[] runs;
}

/// The record's directory in the history, under its merge date (OBH4).
string prDir(in PrRecord r) @safe
{
    const d = SysTime.fromUnixTime(r.merged).toUTC;
    return format("prs/%04d/%02d/%d", d.year, cast(int) d.month, r.number);
}

/// The record as the history stores it: wired's JSON, members in declaration order.
string encode(in PrRecord r) @safe
{
    auto json = toJSON(r);
    return json.hasError ? null : (() @trusted => json.value[].idup)();
}

/// A record read back; an error names what is wrong with it (OBD6, OBP1).
Expected!(PrRecord, string) decode(string text) @safe
{
    auto r = fromJSON!PrRecord(text);
    if (r.hasError)
        return err!PrRecord("not a pull request record");
    if (r.value.schema != prSchema || r.value.version_ != prVersion)
        return err!PrRecord(format("schema %s version %d, not %s version %d", r.value.schema, r.value.version_,
            prSchema, prVersion));
    if (const why = privacyRejection(text, Producer.init))
        return err!PrRecord("holds " ~ why);
    return ok!string(r.value);
}

// === From the provider ===

private long unixOf(string iso) @safe
{
    if (iso.length == 0)
        return 0;
    try
        return SysTime.fromISOExtString(iso).toUnixTime;
    catch (Exception)
        return 0;
}

private long unixOf(Nullable!string iso) @safe => iso.isNull ? 0 : unixOf(iso.get);

private struct GhPullHead
{
    @WireName("ref") string ref_;
    string sha;
}

private struct GhPull
{
    long number;
    @WireName("created_at") string createdAt;
    @WireName("merged_at") Nullable!string mergedAt;
    @WireName("merge_commit_sha") Nullable!string mergeCommit;
    GhPullHead head;
}

private struct GhFile
{
    string filename;
}

private struct GhRunPull
{
    long number;
}

private struct GhPrRun
{
    long id;
    string path;
    string event;
    @WireName("head_sha") string headSha;
    @WireName("created_at") string createdAt;
    @WireName("run_attempt") uint runAttempt = 1;
    @WireName("pull_requests") @WireOptional() GhRunPull[] pullRequests;
}

private struct GhPrRuns
{
    @WireName("total_count") long totalCount;
    @WireName("workflow_runs") GhPrRun[] workflowRuns;
}

private struct GhAttemptJob
{
    long id;
    string name;
    Nullable!string conclusion;
    @WireName("created_at") Nullable!string createdAt;
    @WireName("started_at") Nullable!string startedAt;
    @WireName("completed_at") Nullable!string completedAt;
    @WireOptional() string[] labels;
    @WireName("run_attempt") uint runAttempt = 1;
    @WireOptional() GhStep[] steps;
}

private struct GhAttemptJobs
{
    @WireName("total_count") long totalCount;
    GhAttemptJob[] jobs;
}

/**
Build pull request `number`'s record from the GitHub API of `repo` (OBJ4),
through `fetchJson`, the seam [ci_stats]'s fetch layer defines, so tests feed
saved pages. Every attempt of every run is read; an attempt lists again the
jobs it carried over from an earlier one, and those are counted once, under
the attempt that ran them, by job id.
*/
Result!PrRecord fetchPrRecord(alias fetchJson)(string repo, long number, string token)
{
    auto auth = makeAuthHeaders(token.length ? "Bearer " ~ token : null);
    const base = "https://api.github.com/repos/" ~ repo;
    auto pull = fetchJson!GhPull(format("%s/pulls/%d", base, number), "GET", null, auth);
    if (pull.hasError)
        return err!PrRecord(pull.error);
    const p = pull.value;
    if (p.mergedAt.isNull)
        return err!PrRecord(format("pull request %d is not merged", number));

    PrRecord r;
    r.number = number;
    r.created = unixOf(p.createdAt);
    r.merged = unixOf(p.mergedAt);
    r.head = p.head.sha;
    r.landed = p.mergeCommit.isNull ? null : p.mergeCommit.get;

    foreach (page; 1 .. 31) // at most 3,000 files, the API's own bound
    {
        auto files = fetchJson!(GhFile[])(format("%s/pulls/%d/files?per_page=100&page=%d", base, number, page),
            "GET", null, auth);
        if (files.hasError)
            return err!PrRecord(files.error);
        r.paths ~= files.value.map!(f => f.filename).array;
        if (files.value.length < 100)
            break;
    }
    r.paths = r.paths.sort.uniq.array;

    // A run belongs to the pull request when the provider names it, or, for a
    // fork's run that names none, when it ran on the branch while it was open.
    bool ours(in GhPrRun run)
    {
        if (run.event != "pull_request")
            return false;
        if (run.pullRequests.length)
            return run.pullRequests.any!(q => q.number == number);
        const t = unixOf(run.createdAt);
        return t >= r.created && t <= r.merged;
    }
    foreach (page; 1 .. 11)
    {
        auto runs = fetchJson!GhPrRuns(format("%s/actions/runs?branch=%s&event=pull_request&per_page=100&page=%d",
            base, p.head.ref_, page), "GET", null, auth);
        if (runs.hasError)
            return err!PrRecord(runs.error);
        foreach (ref run; runs.value.workflowRuns)
        {
            if (!ours(run))
                continue;
            PrRun pr = PrRun(run.id, run.path, run.event, run.headSha, unixOf(run.createdAt), run.runAttempt);
            bool[long] seen;
            foreach (attempt; 1 .. run.runAttempt + 1)
                foreach (jpage; 1 .. 6)
                {
                    auto jobs = fetchJson!GhAttemptJobs(format("%s/actions/runs/%d/attempts/%d/jobs?per_page=100&page=%d",
                        base, run.id, attempt, jpage), "GET", null, auth);
                    if (jobs.hasError)
                        return err!PrRecord(jobs.error);
                    foreach (ref j; jobs.value.jobs)
                    {
                        if (j.id in seen)
                            continue;
                        seen[j.id] = true;
                        PrJob job = PrJob(j.name, runnerType(j.labels), j.runAttempt,
                            j.conclusion.isNull ? "" : j.conclusion.get,
                            unixOf(j.createdAt), unixOf(j.startedAt), unixOf(j.completedAt));
                        foreach (ref s; j.steps)
                            if (!s.startedAt.isNull && !s.completedAt.isNull)
                                job.steps ~= PrStep(s.name, unixOf(s.startedAt), unixOf(s.completedAt));
                        pr.jobs ~= job;
                    }
                    if (jobs.value.jobs.length < 100)
                        break;
                }
            r.runs ~= pr;
        }
        if (runs.value.workflowRuns.length < 100)
            break;
    }
    r.runs.sort!((a, b) => a.created < b.created || (a.created == b.created && a.id < b.id));
    return ok!string(r);
}

// === Derived figures (OBJ5) ===

/// Seconds per runner type, and billed minutes (each job rounded up).
struct RunnerTime
{
    string runner;
    long seconds;
    long billedMinutes;
}

/// The three scopes runner time is summed over (OBJ5).
enum Scope
{
    every, /// every attempt of every run
    final_, /// every attempt of each workflow's last run on the final head
    latest, /// the latest execution of each job of those runs
}

/// A job group's figures: the job name up to its first ` (`.
struct GroupTime
{
    string group;
    long seconds;
    size_t jobs;
    size_t failures;
    size_t alone; /// attempts in which it was the only failing group
    size_t flaky; /// failed, then succeeded in a later attempt of the same run
    long rerunSeconds;
}

/// Setup's share of a runner type's time: steps up to and including the caches.
struct SetupTime
{
    string runner;
    long setupSeconds;
    long seconds;
}

/// One job's time in the final run: its latest execution's wait and wall time, in seconds.
struct JobTime
{
    string name;
    string runner;
    long queue;
    long wall;
}

/// The longest and shortest shard of a placement, first attempt on the final head.
struct ShardBalance
{
    string placement;
    long longest;
    long shortest;
}

/// What OBJ5 derives from one record.
struct PrFigures
{
    long number;
    long merged;
    RunnerTime[] every, final_, latest;
    long timeToMerge;
    long timeToGreen;
    long greenToMerge;
    long queueTotal, queueMax;
    long before, waiting, running, after; /// the split of the time to green
    string lastJob;
    long rerunSeconds, cancelledSeconds;
    size_t jobs;
    GroupTime[] groups;
    SetupTime[] setup;
    ShardBalance[] shards;
    string[] paths;
    JobTime[] jobTimes; /// each job of the final run, by name

    long seconds(Scope s) const @safe pure nothrow @nogc
    {
        long t;
        foreach (ref x; s == Scope.every ? every : s == Scope.final_ ? final_ : latest)
            t += x.seconds;
        return t;
    }
}

/// The group a job belongs to: its name up to the matrix's ` (`.
string groupOf(string name) @safe pure nothrow
{
    import std.string : indexOf;

    const i = name.indexOf(" (");
    return i > 0 ? name[0 .. i] : name;
}

/// The workflow's aggregating gate job, which only waits for the others.
private bool isGate(in PrJob j) @safe pure nothrow @nogc => j.name == "CI";

/// Whether a step is setup: it runs before the job's own work.
private bool isSetupStep(string name) @safe pure
    => name.startsWith("Set up job", "Checkout", "Setup Nix", "Cache", "Restore", "Install") != 0;

private RunnerTime[] byRunner(const(PrJob)[] jobs) @safe pure
{
    long[string] secs, billed;
    foreach (ref j; jobs)
        if (j.ran)
        {
            secs[j.runner] += j.wall;
            billed[j.runner] += (j.wall + 59) / 60;
        }
    return secs.keys.sort.map!(k => RunnerTime(k, secs[k], billed[k])).array;
}

/// Everything OBJ5 defines, from one record.
PrFigures figuresOf(in PrRecord r) @safe
{
    import perf_publish : placementOfJob;

    PrFigures f;
    f.number = r.number;
    f.merged = r.merged;
    f.paths = r.paths.dup;
    f.timeToMerge = r.merged - r.created;

    const(PrJob)[] all;
    foreach (ref run; r.runs)
        all ~= run.jobs;
    f.jobs = all.length;
    f.every = byRunner(all);
    foreach (ref j; all)
    {
        f.queueTotal += j.queue;
        if (j.queue > f.queueMax)
            f.queueMax = j.queue;
        if (j.attempt > 1)
            f.rerunSeconds += j.wall;
        if (j.conclusion == "cancelled")
            f.cancelledSeconds += j.wall;
    }

    // Each workflow's last run on the final head, by index into r.runs.
    size_t[string] lastOf;
    foreach (i, ref run; r.runs)
    {
        if (run.head != r.head)
            continue;
        if (auto p = run.workflow in lastOf)
        {
            if (run.created > r.runs[*p].created)
                *p = i;
        }
        else
            lastOf[run.workflow] = i;
    }
    const(PrRun)[] finals = lastOf.keys.sort.map!(k => r.runs[lastOf[k]]).array;
    const(PrJob)[] finalJobs, latestJobs;
    foreach (ref run; finals)
    {
        finalJobs ~= run.jobs;
        size_t[string] newest;
        foreach (i, ref j; run.jobs)
            if (auto p = j.name in newest)
            {
                if (j.attempt > run.jobs[*p].attempt)
                    *p = i;
            }
            else
                newest[j.name] = i;
        foreach (k; newest.keys.sort)
            latestJobs ~= run.jobs[newest[k]];
    }
    f.final_ = byRunner(finalJobs);
    foreach (ref j; latestJobs)
        if (j.ran && !isGate(j))
            f.jobTimes ~= JobTime(j.name, j.runner, j.queue, j.wall);
    f.latest = byRunner(latestJobs);

    // Time to green, and its split along the last job that ran a minute.
    if (finals.length)
    {
        const t0 = finals.map!(x => x.created).minElement;
        const ranJobs = finalJobs.filter!(j => j.ran).array;
        if (ranJobs.length)
        {
            const done = ranJobs.map!(j => j.end).maxElement;
            f.timeToGreen = done - t0;
            f.greenToMerge = r.merged > done ? r.merged - done : 0;
            const substantial = ranJobs.filter!(j => !isGate(j) && j.wall >= 60).array;
            if (substantial.length)
            {
                size_t li;
                foreach (i, ref j; substantial)
                    if (j.end > substantial[li].end)
                        li = i;
                const last = substantial[li];
                f.lastJob = last.name;
                f.before = last.created > t0 ? last.created - t0 : 0;
                f.waiting = last.queue;
                f.running = last.wall;
                f.after = done - last.end;
            }
        }
    }

    // Groups: cost, failures, lone failures, flakiness, reruns.
    GroupTime[string] g;
    foreach (ref j; all)
    {
        auto x = &g.require(groupOf(j.name), GroupTime(groupOf(j.name)));
        x.seconds += j.wall;
        ++x.jobs;
        if (j.conclusion == "failure")
            ++x.failures;
        if (j.attempt > 1)
            x.rerunSeconds += j.wall;
    }
    foreach (ref run; r.runs)
    {
        foreach (attempt; 1 .. run.attempts + 1)
        {
            auto failing = run.jobs.filter!(j => j.attempt == attempt && j.conclusion == "failure" && !isGate(j))
                .map!(j => groupOf(j.name)).array.sort.uniq.array;
            if (failing.length == 1)
                ++g[failing[0]].alone;
        }
        bool[string] counted;
        foreach (ref j; run.jobs)
            if (j.conclusion == "failure" && j.name !in counted
                && run.jobs.any!(k => k.name == j.name && k.attempt > j.attempt && k.conclusion == "success"))
            {
                counted[j.name] = true;
                ++g[groupOf(j.name)].flaky;
            }
    }
    f.groups = g.keys.sort.map!(k => g[k]).array;

    // Setup per runner type.
    long[string] setup, secs;
    foreach (ref j; all)
        if (j.ran)
        {
            secs[j.runner] += j.wall;
            foreach (ref s; j.steps)
                if (isSetupStep(s.name) && s.end >= s.start)
                    setup[j.runner] += s.end - s.start;
        }
    f.setup = secs.keys.sort.map!(k => SetupTime(k, setup.get(k, 0), secs[k])).array;

    // Shard balance: the final head's first attempt, every shard succeeded.
    long[][string] shardWalls;
    size_t[string] expected;
    foreach (ref run; finals)
        foreach (ref j; run.jobs)
        {
            const ps = placementOfJob(j.name);
            if (ps[0] is null || j.attempt != 1 || j.conclusion != "success")
                continue;
            import std.string : indexOf;

            const slash = ps[1].indexOf('/');
            shardWalls[ps[0]] ~= j.wall;
            expected[ps[0]] = slash > 0 ? ps[1][slash + 1 .. $].to!size_t : 1;
        }
    foreach (k; shardWalls.keys.sort)
        if (shardWalls[k].length >= 2 && shardWalls[k].length == expected[k])
            f.shards ~= ShardBalance(k, shardWalls[k].maxElement, shardWalls[k].minElement);
    return f;
}

version (unittest)
{
    /// A fixture: two pushes, a rerun of one failed job, a job that never
    /// started, carried-over jobs and the gate (oracle 18).
    PrRecord fixtureRecord() @safe pure
    {
        PrRecord r;
        r.number = 7;
        r.created = 1000;
        r.merged = 1000 + 7200;
        r.head = "bbbb";
        r.landed = "cccc";
        r.paths = ["libs/base/src/x.d"];
        // The first push, superseded: one cancelled job.
        r.runs ~= PrRun(1, ".github/workflows/ci.yml", "pull_request", "aaaa", 1000, 1,
            [PrJob("test (x86_64-linux-ldc2, 1/2)", "ubuntu-latest", 1, "cancelled", 1000, 1010, 1310)]);
        // The final push: attempt 1 fails a slow test, attempt 2 reruns it.
        r.runs ~= PrRun(2, ".github/workflows/ci.yml", "pull_request", "bbbb", 2000, 2, [
            PrJob("test (x86_64-linux-ldc2, 1/2)", "ubuntu-latest", 1, "success", 2000, 2060, 2660,
                [PrStep("Set up job", 2060, 2070), PrStep("Setup Nix", 2070, 2160)]),
            PrJob("test (x86_64-linux-ldc2, 2/2)", "ubuntu-latest", 1, "success", 2000, 2100, 2500),
            PrJob("slow (x86_64-linux, ldc2, oracle.x)", "macos-latest", 1, "failure", 2000, 2300, 2420),
            PrJob("CI", "ubuntu-latest", 1, "failure", 2660, 2661, 2662),
            PrJob("lint", "ubuntu-latest", 1, "skipped", 2000, 0, 0),
            PrJob("slow (x86_64-linux, ldc2, oracle.x)", "macos-latest", 2, "success", 3000, 3030, 3150),
            PrJob("CI", "ubuntu-latest", 2, "success", 3150, 3151, 3152),
        ]);
        return r;
    }
}

@("perfPr.figuresOf.handComputed")
@safe unittest
{
    const f = figuresOf(fixtureRecord());
    // every attempt of every run: ubuntu 300 + 600 + 400 + 1 + 1, macOS 120 + 120
    assert(f.every == [RunnerTime("macos-latest", 240, 4), RunnerTime("ubuntu-latest", 1302, 5 + 10 + 7 + 1 + 1)]);
    assert(f.final_ == [RunnerTime("macos-latest", 240, 4), RunnerTime("ubuntu-latest", 1002, 10 + 7 + 1 + 1)]);
    // latest executions: the rerun replaces the failed slow job, and the gate's second run its first
    assert(f.latest == [RunnerTime("macos-latest", 120, 2), RunnerTime("ubuntu-latest", 1001, 10 + 7 + 1)]);
    assert(f.timeToMerge == 7200);
    assert(f.timeToGreen == 3152 - 2000, "the final head's first run to its last job");
    assert(f.greenToMerge == 8200 - 3152);
    assert(f.lastJob == "slow (x86_64-linux, ldc2, oracle.x)", "the gate only waits; it is not followed");
    assert(f.before == 1000 && f.waiting == 30 && f.running == 120 && f.after == 2);
    assert(f.before + f.waiting + f.running + f.after == f.timeToGreen);
    assert(f.rerunSeconds == 120 + 1 && f.cancelledSeconds == 300);
    assert(f.queueMax == 300 && f.jobs == 8);
    const slow = f.groups.filter!(x => x.group == "slow").front;
    assert(slow.failures == 1 && slow.alone == 1 && slow.flaky == 1, "failed alone, then passed: flaky");
    assert(f.setup == [SetupTime("macos-latest", 0, 240), SetupTime("ubuntu-latest", 100, 1302)]);
    assert(f.shards == [ShardBalance("x86_64-linux-ldc2", 600, 400)]);
    assert(f.jobTimes.map!(j => j.name).array == ["slow (x86_64-linux, ldc2, oracle.x)",
        "test (x86_64-linux-ldc2, 1/2)", "test (x86_64-linux-ldc2, 2/2)"], "the gate and a job that never ran aside");
    assert(f.jobTimes[0] == JobTime("slow (x86_64-linux, ldc2, oracle.x)", "macos-latest", 30, 120),
        "the rerun, the latest execution");
}

@("perfPr.encode.roundTripAndPrivacy")
@safe unittest
{
    auto r = fixtureRecord();
    const text = encode(r);
    assert(text.startsWith(`{"schema":"sparkles.perf.pr","version":1,"number":7,`), text);
    const back = decode(text);
    assert(back.hasValue, back.hasError ? back.error : "");
    assert(back.value == r);
    assert(prDir(r) == "prs/1970/01/7");

    auto leaky = r;
    leaky.paths ~= "/home/someone/x";
    assert(decode(encode(leaky)).hasError, "an absolute path is refused");
    assert(decode(`{"schema":"sparkles.perf.run","version":1,"number":1,"created":0,"merged":0,"head":"","landed":""}`)
        .hasError);
}

version (unittest)
{
    /// The pages a test saved, keyed by the URL's path and query under the repository.
    package string[string] savedPages;

    /// A fetch that serves $(LREF savedPages): the seam's test side.
    package Result!T savedPage(T)(string url, string method, string body, const string[string] headers) @safe
    {
        import std.string : indexOf;

        const at = url.indexOf("/repos/o/r/");
        const key = at < 0 ? url : url[at + "/repos/o/r/".length .. $];
        if (auto page = key in savedPages)
        {
            auto decoded = fromJSON!T(*page);
            return decoded.hasError ? err!T("bad page " ~ key) : ok!string(decoded.value);
        }
        return err!T("no saved page for " ~ key);
    }
}

@("perfPr.fetchPrRecord.savedPages")
@system unittest
{
    import std.string : indexOf;

    // Saved API pages, keyed by the URL's path and query; attempt 2 lists the
    // job attempt 1 ran again, which is counted once.
    savedPages = [
        "pulls/7": `{"number":7,"created_at":"2026-11-18T10:00:00Z","merged_at":"2026-11-18T12:00:00Z",`
            ~ `"merge_commit_sha":"cccc","title":"secret title","user":{"login":"someone"},`
            ~ `"head":{"ref":"feat/x","sha":"bbbb"}}`,
        "pulls/7/files?per_page=100&page=1": `[{"filename":"libs/base/src/x.d"},{"filename":"README.md"}]`,
        "actions/runs?branch=feat/x&event=pull_request&per_page=100&page=1": `{"total_count":2,"workflow_runs":[`
            ~ `{"id":2,"path":".github/workflows/ci.yml","event":"pull_request","head_sha":"bbbb",`
            ~ `"created_at":"2026-11-18T10:10:00Z","run_attempt":2,"pull_requests":[{"number":7}]},`
            ~ `{"id":3,"path":".github/workflows/ci.yml","event":"pull_request","head_sha":"zzzz",`
            ~ `"created_at":"2026-11-18T10:10:00Z","run_attempt":1,"pull_requests":[{"number":8}]}]}`,
        "actions/runs/2/attempts/1/jobs?per_page=100&page=1": `{"total_count":2,"jobs":[`
            ~ `{"id":11,"name":"build","conclusion":"success","created_at":"2026-11-18T10:10:00Z",`
            ~ `"started_at":"2026-11-18T10:11:00Z","completed_at":"2026-11-18T10:21:00Z",`
            ~ `"labels":["ubuntu-latest"],"run_attempt":1,"runner_name":"GitHub Actions 42","steps":[]},`
            ~ `{"id":12,"name":"test","conclusion":"failure","created_at":"2026-11-18T10:10:00Z",`
            ~ `"started_at":"2026-11-18T10:11:00Z","completed_at":"2026-11-18T10:15:00Z",`
            ~ `"labels":["self-hosted","pc-of-someone"],"run_attempt":1}]}`,
        "actions/runs/2/attempts/2/jobs?per_page=100&page=1": `{"total_count":2,"jobs":[`
            ~ `{"id":11,"name":"build","conclusion":"success","created_at":"2026-11-18T10:10:00Z",`
            ~ `"started_at":"2026-11-18T10:11:00Z","completed_at":"2026-11-18T10:21:00Z",`
            ~ `"labels":["ubuntu-latest"],"run_attempt":1},`
            ~ `{"id":13,"name":"test","conclusion":"success","created_at":"2026-11-18T10:30:00Z",`
            ~ `"started_at":"2026-11-18T10:31:00Z","completed_at":"2026-11-18T10:35:00Z",`
            ~ `"labels":["ubuntu-latest"],"run_attempt":2}]}`,
    ];
    const got = fetchPrRecord!savedPage("o/r", 7, "t");
    assert(got.hasValue, got.hasError ? got.error : "");
    const r = got.value;
    assert(r.head == "bbbb" && r.landed == "cccc" && r.paths == ["README.md", "libs/base/src/x.d"]);
    assert(r.runs.length == 1, "the other pull request's run is not this one's");
    assert(r.runs[0].jobs.length == 3, "the carried-over build is counted once");
    assert(r.runs[0].jobs.map!(j => j.runner).array == ["ubuntu-latest", "<label>", "ubuntu-latest"]);
    const text = encode(r);
    foreach (secret; ["secret title", "someone", "GitHub Actions 42", "pc-of-someone", "feat/x"])
        assert(text.indexOf(secret) < 0, secret ~ " reached the record");
}

// === Publishing (OBH4, OBQ9) ===

/// Where `ci perf import-prs` writes records for `ci perf push` (OBH6).
string localPrRoot() @safe
{
    import std.path : buildPath, expandTilde;
    import std.process : environment;

    const cache = cacheHome();
    return buildPath(cache, "sparkles", "perf", "prs");
}

private struct GhCommitPull
{
    long number;
    @WireName("merged_at") Nullable!string mergedAt;
    @WireName("merge_commit_sha") Nullable!string mergeCommit;
}

/// The merged pull request that landed `commit`, or 0 when none names it.
Result!long pullRequestOf(alias fetchJson)(string repo, string commit, string token)
{
    auto auth = makeAuthHeaders(token.length ? "Bearer " ~ token : null);
    auto pulls = fetchJson!(GhCommitPull[])(format("https://api.github.com/repos/%s/commits/%s/pulls", repo,
        commit), "GET", null, auth);
    if (pulls.hasError)
        return err!long(pulls.error);
    foreach (ref p; pulls.value)
        if (!p.mergedAt.isNull)
            return ok!string(p.number);
    return ok!string(0L);
}

/// The record as the history holds it: one directory, one file.
private auto appendOf(in PrRecord r) @safe
{
    import perf_history : Append, RecordFiles;

    return Append(prDir(r), RecordFiles(format("pr-%d", r.number), ["pr.json": encode(r)]));
}

/// A record about to be published, checked as a reader would check it.
private string rejection(in PrRecord r) @safe
{
    const text = encode(r);
    if (text is null)
        return "cannot be encoded";
    const back = decode(text);
    return back.hasError ? back.error : null;
}

/**
`ci perf append`'s pull request step (OBH4): the record of the pull request
that landed `landedCommit`, built from the API and appended, signed with
`signingKey`. A landing no pull request names appends nothing.
*/
Expected!(string, string) appendLandedPr(alias fetchJson)(string repo, string landedCommit, string token,
    string signingKey, string remote, string signersFile) @trusted
{
    import perf_history : appendRecords, historyCacheDir;

    auto number = pullRequestOf!fetchJson(repo, landedCommit, token);
    if (number.hasError)
        return err!string(number.error);
    if (number.value == 0)
        return ok!string(format("no pull request landed %s; no pull request record", landedCommit[0 .. 12]));
    auto rec = fetchPrRecord!fetchJson(repo, number.value, token);
    if (rec.hasError)
        return err!string(rec.error);
    rec.value.landed = landedCommit;
    if (const why = rejection(rec.value))
        return err!string(format("pull request %d's record %s", number.value, why));
    auto done = appendRecords(historyCacheDir(remote), remote, signersFile, [appendOf(rec.value)], signingKey,
        format("append the record of pull request %d", number.value));
    if (done.hasError)
        return err!string(done.error);
    return ok!string(done.value.length ? "appended " ~ done.value[0] : format("pull request %d's record is present",
        number.value));
}

private struct GhClosedPull
{
    long number;
    @WireName("merged_at") Nullable!string mergedAt;
    @WireName("updated_at") string updatedAt;
}

/**
`ci perf import-prs` (OBQ9): write the record of every pull request of `repo`
merged on or after `since` (`YYYY-MM-DD`) under $(LREF localPrRoot), for
`ci perf push` to publish.
*/
Expected!(string, string) importPrs(alias fetchJson)(string repo, string since, string token) @trusted
{
    import std.file : mkdirRecurse, write;
    import std.path : buildPath;

    auto auth = makeAuthHeaders(token.length ? "Bearer " ~ token : null);
    const from = unixOf(since ~ "T00:00:00Z");
    if (from == 0)
        return err!string("--since " ~ since ~ " is not a date YYYY-MM-DD");
    long[] numbers;
    foreach (page; 1 .. 51)
    {
        auto pulls = fetchJson!(GhClosedPull[])(format(
            "https://api.github.com/repos/%s/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=%d",
            repo, page), "GET", null, auth);
        if (pulls.hasError)
            return err!string(pulls.error);
        foreach (ref p; pulls.value)
            if (!p.mergedAt.isNull && unixOf(p.mergedAt) >= from)
                numbers ~= p.number;
        // Sorted by update: once a page ends before `since`, no later page merges after it.
        if (pulls.value.length < 100 || unixOf(pulls.value[$ - 1].updatedAt) < from)
            break;
    }
    mkdirRecurse(localPrRoot());
    string report;
    size_t written;
    foreach (n; numbers.sort.uniq)
    {
        auto rec = fetchPrRecord!fetchJson(repo, n, token);
        if (rec.hasError)
        {
            report ~= format("skipped pull request %d: %s\n", n, rec.error);
            continue;
        }
        if (const why = rejection(rec.value))
        {
            report ~= format("skipped pull request %d: its record %s\n", n, why);
            continue;
        }
        write(buildPath(localPrRoot(), format("%d.json", n)), encode(rec.value));
        ++written;
    }
    return ok!string(report ~ format("wrote %d pull request record(s) to %s", written, localPrRoot()));
}

/// The records `ci perf import-prs` wrote, for `ci perf push` (OBH6).
auto localPrAppends(out string report) @trusted
{
    import std.file : dirEntries, exists, readText, SpanMode;
    import perf_history : Append;

    Append[] appends;
    if (!exists(localPrRoot()))
        return appends;
    foreach (e; dirEntries(localPrRoot(), "*.json", SpanMode.shallow))
    {
        auto rec = decode(readText(e.name));
        if (rec.hasError)
        {
            report ~= "skipped " ~ e.name ~ ": " ~ rec.error ~ "\n";
            continue;
        }
        appends ~= appendOf(rec.value);
    }
    appends.sort!((a, b) => a.dir < b.dir);
    return appends;
}
