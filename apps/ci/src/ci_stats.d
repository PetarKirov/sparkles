/++
`ci --ci-stats` — GitHub Actions CI usage statistics subcommand.

See `docs/specs/ci/stats/SPEC.md` (normative contract) and `PLAN.md` (milestones).

This module owns:
- Domain data models (`Job`, `JobStats`, `RunnerAggregate` …)
- The injectable fetch policy (`fetchAndDeserializeJson` seam)
- Pure statistical pipelines (std.algorithm + std.range only)
- Rendering (LiveRegion / TaskReporter + drawTable* + SmallBuffer durations)

All non-trivial data transformation after the JSON→domain boundary must be range pipelines.
+/
module ci_stats;

import std.algorithm.iteration : fold, map, filter;
import std.algorithm.searching : canFind, minElement, maxElement;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.conv : to, text;
import std.datetime : SysTime;
import std.json : parseJSON;
import std.net.curl : HTTP;
import std.range : drop, isInputRange, walkLength, take, ElementType;
import std.range.primitives : empty, front;
import std.stdio : writeln;
import std.string : strip;
import std.typecons : Nullable, tuple;
import std.uri : encodeComponent;

import core.time : Duration;

import expected : Expected, ok, err;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.styled_template : styledWriteln;
import sparkles.base.text.writers : writeDuration, writeFixedPoint, writeInteger;

import sparkles.core_cli.term_caps : detectTermCaps;
import sparkles.core_cli.ui.live : stdoutLiveRegion;
import sparkles.core_cli.ui.table : drawTable, drawTableLines, TableProps;
import sparkles.core_cli.ui.tasklist : TaskReporter;
import sparkles.core_cli.ui.theme : makeTheme, Theme;

import sparkles.wired : fromJSON, WireName;

// ---------------------------------------------------------------------------
// Result vocabulary (mirrors the release app pattern for consistency)
// ---------------------------------------------------------------------------

alias Result(T) = Expected!(T, string);

Result!T success(T)(T value) => ok!string(value);
Result!T failure(T)(string message) => err!T(message);

// ---------------------------------------------------------------------------
// Domain models (pure, minimal, wired-decodable response models are private)
// ---------------------------------------------------------------------------

struct Job
{
    string name;
    string workflow;
    Duration duration;
    string[] labels;
    string runnerName;
    string conclusion;
}

struct JobStats
{
    size_t count;
    Duration total;
    Duration min;
    Duration max;
    Duration mean;
    Duration median;
    Duration p95;
}

struct RunnerAggregate
{
    string runnerType;
    JobStats stats;
    // No stored double minutes. "CI minutes" display values are derived from
    // stats.total at render time (using Duration-based writers or scaled
    // fixed-point). This keeps all aggregates in Duration.
}

// ---------------------------------------------------------------------------
// GitHub API response models (for wired deserialization)
// ---------------------------------------------------------------------------

struct GhWorkflowRun
{
    long id;
    // GitHub marks `name` nullable (e.g. old or startup-failure runs); a plain
    // `string` would abort the whole page decode on a null. `path` is always present.
    Nullable!string name;
    string path;
    @WireName("workflow_name") Nullable!string workflowName;
}

struct GhRunsResponse
{
    long total_count;
    @WireName("workflow_runs") GhWorkflowRun[] workflowRuns;
}

struct GhJob
{
    long id;
    string name;
    Nullable!string conclusion;
    @WireName("started_at") Nullable!string startedAt;
    @WireName("completed_at") Nullable!string completedAt;
    string[] labels;
    @WireName("runner_name") Nullable!string runnerName;
}

struct GhJobsResponse
{
    long total_count;
    GhJob[] jobs;
}

// ---------------------------------------------------------------------------
// Fetch policy (the seam that enables mocking)
//
// Real code passes `fetchAndDeserializeJson`.
// Tests pass a local template that returns pre-built T values directly.
// ---------------------------------------------------------------------------

/// Signature for a typed fetch+deserialize step.
/// method is "GET" (REST) or "POST" (GraphQL with body).
/// Implementations must honour the GitHub required headers and token policy.
alias FetchJson(T) = Result!T delegate(
    string url,
    string method = "GET",
    string body = null,
    string[string] extraHeaders = null,
);

/// Truncate `s` to at most `maxBytes` bytes without splitting a UTF-8 code
/// point (backs off the cut while it lands on a `0x80–0xBF` continuation byte),
/// appending an ellipsis when anything was dropped.
string truncateUtf8(string s, size_t maxBytes) @safe pure nothrow
{
    if (s.length <= maxBytes)
        return s;
    size_t cut = maxBytes;
    while (cut > 0 && (s[cut] & 0xC0) == 0x80)
        --cut;
    return s[0 .. cut] ~ "…";
}

/// Production implementation using std.net.curl + wired deserialization.
/// Supports REST (GET) and GraphQL (POST with JSON body).
/// Caller must supply Authorization header content if needed (via extraHeaders or separate).
///
/// Uses the low-level `HTTP` + `perform` API rather than the free `get`/`post`
/// functions: those throw `HTTPStatusException` on any non-2xx status *before*
/// returning content, which would discard GitHub's explanatory error body.
/// `perform` only throws on transport-level failures (still handled by the catch).
Result!T fetchAndDeserializeJson(T)(
    string url,
    string method = "GET",
    string body = null,
    string[string] extraHeaders = null,
)
{
    try
    {
        auto http = HTTP(url);
        http.method = (method == "POST" ? HTTP.Method.post : HTTP.Method.get);

        http.addRequestHeader("Accept", "application/vnd.github+json");
        http.addRequestHeader("X-GitHub-Api-Version", "2022-11-28");
        http.addRequestHeader("User-Agent", "sparkles-ci/0.1");

        foreach (k, v; extraHeaders)
            http.addRequestHeader(k, v);

        if (method == "POST" && body.length)
            http.setPostData(body, "application/json");

        ubyte[] buf;
        http.onReceive = (ubyte[] data) { buf ~= data; return data.length; };
        http.perform();

        const status = http.statusLine.code;
        string responseText = cast(string) buf;
        if (status < 200 || status >= 300)
        {
            string msg = "GitHub API HTTP " ~ status.to!string ~ ": "
                ~ truncateUtf8(responseText.strip, 200);
            // Rate-limit responses carry a reset epoch (SPEC §4) — surface it.
            if (status == 403 || status == 429)
                if (auto reset = "x-ratelimit-reset" in http.responseHeaders)
                {
                    try
                        msg ~= " (rate limit resets at "
                            ~ SysTime.fromUnixTime((*reset).to!long).toUTC.toISOExtString ~ ")";
                    catch (Exception) { /* leave message as-is on a malformed header */ }
                }
            return failure!T(msg);
        }

        auto dom = parseJSON(responseText);
        auto decoded = fromJSON!T(dom);
        if (decoded.hasError)
            return failure!T("JSON decode error: " ~ decoded.error.msg);

        return success(decoded.value);
    }
    catch (Exception e)
    {
        return failure!T("HTTP/fetch error: " ~ e.msg);
    }
}

// ---------------------------------------------------------------------------
// Pure statistics (everything after domain objects uses range pipelines)
// ---------------------------------------------------------------------------

string normalizeRunnerKey(scope const(string)[] labels) @safe pure nothrow
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import std.array : array, join;

    if (labels.canFind("self-hosted"))
    {
        auto rest = labels
            .filter!(l => l != "self-hosted")
            .array
            .dup
            .sort
            .release;
        return "self-hosted" ~ (rest.length ? "+" ~ rest.join("+") : "");
    }
    return labels.length ? labels[0].idup : "(unknown)";
}

/// Compute min/max/mean/median/p95 etc. from a range of Jobs (or Durations).
JobStats computeStats(R)(R jobs)
if (isInputRange!R)
{
    import std.algorithm.iteration : map, filter;
    import std.algorithm.searching : minElement, maxElement;
    import std.array : array;
    import std.range : walkLength, take, drop;

    auto durs = jobs
        .filter!(j => j.duration > Duration.zero)
        .map!(j => j.duration)
        .array;

    if (durs.length == 0)
        return JobStats.init;

    auto sorted = durs.dup;
    sorted.sort();

    JobStats s;
    s.count = durs.length;
    s.total = durs.fold!((a, b) => a + b)(Duration.zero);
    s.min = sorted.minElement;
    s.max = sorted.maxElement;
    s.mean = s.total / s.count;

    // median
    auto mid = s.count / 2;
    s.median = (s.count % 2 == 1)
        ? sorted[mid]
        : (sorted[mid-1] + sorted[mid]) / 2;

    // p95 (simple index; good enough for the spec)
    size_t p95Idx = cast(size_t)(0.95 * (s.count - 1));
    s.p95 = sorted[p95Idx < sorted.length ? p95Idx : $ - 1];

    return s;
}

RunnerAggregate[] aggregateByRunner(R)(R jobs) @safe pure
if (isInputRange!R && is(ElementType!R == Job))
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.typecons : tuple;

    // Use sort + manual consecutive grouping (library group had type issues in this context;
    // the accumulation is small and followed by range post-processing for the result).
    auto keyed = jobs
        .map!(j => tuple(normalizeRunnerKey(j.labels), j))
        .array
        .sort!((a, b) => a[0] < b[0])
        .release;

    RunnerAggregate[] result;
    if (keyed.empty) return result;

    string currentKey = keyed.front[0];
    auto group = [keyed.front[1]];
    foreach (t; keyed.drop(1))
    {
        if (t[0] != currentKey)
        {
            auto st = computeStats(group);
            result ~= RunnerAggregate(currentKey, st);
            currentKey = t[0];
            group = [t[1]];
        }
        else
        {
            group ~= t[1];
        }
    }
    auto st = computeStats(group);
    result ~= RunnerAggregate(currentKey, st);
    return result;
}

// ---------------------------------------------------------------------------
// Rendering helpers (SmallBuffer + writers for durations, UI stack for tables)
// ---------------------------------------------------------------------------

// These `fmt*` return `string` because the table APIs (`string[][]` / `Cell`)
// require owning string content for cells. They are thin adapters over the
// project's writer primitives.
//
// Preferred style elsewhere (IES, task details, logs):
//   SmallBuffer!(char, N) buf;
//   writeDuration(buf, d);
//   styledWriteln(i"... $(buf[]) ...");
// or using the TaskReporter proxy for live output.
//
// See the direct buffer usage in the header stats and some task outputs below.

string fmtDur(Duration d)
{
    SmallBuffer!(char, 32) buf;
    writeDuration(buf, d);
    return buf[].idup;
}

string fmtCount(size_t n)
{
    SmallBuffer!(char, 16) buf;
    writeInteger(buf, n);
    return buf[].idup;
}

string fmtMinutesFromTotal(Duration total)
{
    // Derive display minutes from Duration *only* at render time.
    // We never store double minutes in RunnerAggregate / aggregates.
    // Use scaled fixed-point + writeFixedPoint for clean 1-decimal bare number
    // (the table column header already provides the "Minutes" unit).
    double m = total.total!"seconds" / 60.0;
    ulong scaled = cast(ulong)(m * 10.0 + 0.5);
    SmallBuffer!(char, 16) buf;
    writeFixedPoint(buf, scaled, 1);
    return buf[].idup;
}

string[string] makeAuthHeaders(string authHeader)
{
    string[string] h;
    if (authHeader.length)
        h["Authorization"] = authHeader;
    return h;
}

auto jobsWithDuration(R)(R jobs)
{
    return jobs.filter!(j => j.duration > Duration.zero);
}

Job[] topSlowJobs(R)(R jobs, size_t n = 5) @safe pure
if (isInputRange!R && is(ElementType!R == Job))
{
    import std.algorithm.sorting : sort;
    import std.range : take;

    auto arr = jobs.array;
    arr.sort!((a, b) => a.duration > b.duration);
    return arr.take(n).array;
}

void renderReport(in JobStats overall, in RunnerAggregate[] byRunner, Job[] slowJobs, in Theme theme)
{
    import std.stdio : writeln;
    import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;

    writeln();
    writeln(drawHeader("CI Usage Statistics", HeaderProps(style: HeaderStyle.banner)));

    // Overall stats: use direct SmallBuffer + writers + slice in IES.
    // This avoids fmt* allocation for temporary display values.
    {
        SmallBuffer!(char, 32) totalBuf, minBuf, maxBuf, avgBuf, medBuf, p95Buf;
        writeDuration(totalBuf, overall.total);
        writeDuration(minBuf, overall.min);
        writeDuration(maxBuf, overall.max);
        writeDuration(avgBuf, overall.mean);
        writeDuration(medBuf, overall.median);
        writeDuration(p95Buf, overall.p95);

        styledWriteln(i"Jobs: $(overall.count)   Total: $(totalBuf[])");
        styledWriteln(i"Min: $(minBuf[])  Max: $(maxBuf[])  Avg: $(avgBuf[])  Median: $(medBuf[])  p95: $(p95Buf[])");
    }

    // Runner aggregates table - richer with per-runner stats (using range style data prep)
    string[][] runnerRows = [["Runner Type", "Jobs", "Total", "Avg", "Min", "Max", "Minutes"]];
    foreach (r; byRunner)
    {
        auto s = r.stats;
        runnerRows ~= [
            r.runnerType,
            fmtCount(s.count),
            fmtDur(s.total),
            fmtDur(s.mean),
            fmtDur(s.min),
            fmtDur(s.max),
            fmtMinutesFromTotal(r.stats.total)
        ];
    }

    writeln();
    writeln(drawTable(runnerRows, TableProps(headerRows: 1, title: "By Runner Type")));

    if (!slowJobs.empty)
    {
        string[][] slowRows = [["#", "Job", "Workflow", "Duration", "Runner"]];
        foreach (i, j; slowJobs)
        {
            slowRows ~= [
                fmtCount(i + 1),
                j.name,
                j.workflow,
                fmtDur(j.duration),
                j.runnerName.length ? j.runnerName : "-"
            ];
        }
        writeln();
        writeln(drawTable(slowRows, TableProps(headerRows: 1, title: "Top Slow Jobs")));
    }
}

// ---------------------------------------------------------------------------
// Mock support demonstration (for unit testing the pure logic)
// As required: the fetcher is template param, so domain can be tested with
// direct T returns, no network.
// ---------------------------------------------------------------------------

@("ci_stats.runCiStats.injectablePathCompiles")
@system unittest
{
    // Compile-only check that the injectable fetch seam type-checks. We must NOT
    // *run* runCiStats here: it spins up a real stdout live region and would paint
    // a stray failed-task frame into every `dub test :ci`. `__traits(compiles)`
    // instantiates the whole path (semantic3) without executing it.
    auto dummyFetch(T)(string, string = "GET", string = null, string[string] = null)
        => failure!T("mock not populated in this compile-test");
    auto o = CiStatsOptions("owner/repo", "", 5);
    static assert(__traits(compiles, runCiStats!dummyFetch(o)));
}

// ---------------------------------------------------------------------------
// Core orchestration (templated on fetcher for testability)
// ---------------------------------------------------------------------------

struct CiStatsOptions
{
    string repo;
    string token;
    int limit = 100;
    string since;
    string workflowFilter;
    string conclusionFilter;
}

/// High-level entry: templated so callers (or tests) can inject a fetcher
/// that directly returns T without network.
Result!Report runCiStats(alias fetchJson)(in CiStatsOptions opts)
{
    import std.algorithm.comparison : min;
    import std.conv : to;

    if (opts.repo.length == 0)
        return failure!Report("repo is required (owner/repo)");

    // Primary validation is in app.d's validateCliMode (pre-network); this guards
    // the templated entry that tests/other callers invoke directly. A non-positive
    // limit would otherwise promote to a huge size_t in the loop/slice below.
    if (opts.limit <= 0)
        return failure!Report("--limit must be a positive integer");

    string authHeader = opts.token.length ? "Bearer " ~ opts.token : null;

    auto region = stdoutLiveRegion();
    scope (exit) region.finish();

    const theme = makeTheme(detectTermCaps());
    auto tasks = TaskReporter(&region, theme);

    // 1. Fetch runs (paginated)
    const runsId = tasks.add("fetch workflow runs");
    tasks.start(runsId);

    GhWorkflowRun[] runs;
    bool[long] seenRuns;  // dedup by run.id: created-desc pages shift when runs start mid-fetch
    int page = 1;
    const perPage = 100;
    string baseUrl = "https://api.github.com/repos/" ~ opts.repo ~ "/actions/runs";

    while (runs.length < opts.limit)
    {
        string url = baseUrl ~ "?per_page=" ~ perPage.to!string ~ "&page=" ~ page.to!string;
        if (opts.since.length)
            url ~= "&created=" ~ encodeComponent(">=" ~ opts.since);

        auto r = fetchJson!GhRunsResponse(url, "GET", null, makeAuthHeaders(authHeader));
        if (r.hasError)
        {
            tasks.fail(runsId, r.error);
            return failure!Report(r.error);
        }

        auto rawPage = r.value.workflowRuns;
        if (rawPage.length == 0)
            break;

        foreach (run; rawPage)
        {
            if (run.id in seenRuns)
                continue;
            seenRuns[run.id] = true;

            if (opts.workflowFilter.length)
            {
                const nameMatch = !run.name.isNull && run.name.get.canFind(opts.workflowFilter);
                if (!nameMatch && !run.path.canFind(opts.workflowFilter))
                    continue;
            }

            runs ~= run;
            if (runs.length >= opts.limit)
                break;
        }

        tasks.output(runsId).writeStyled(i"$(runs.length) runs so far");

        // Break on the RAW page length — a short *filtered* page is not the last page.
        if (rawPage.length < perPage)
            break;
        ++page;
    }

    runs = runs[0 .. min($, opts.limit)];
    tasks.succeed(runsId, text(runs.length, " runs"));

    if (runs.length == 0)
        return success(Report.init);

    // 2. For each run, fetch jobs (with progress)
    const jobsId = tasks.add("fetch jobs for runs");
    tasks.start(jobsId);

    Job[] allJobs;
    size_t failedRuns;  // runs whose jobs could not be fetched — stats would be incomplete
    foreach (i, run; runs)
    {
        // The run's display name (workflow_name, else the run name) — used for every job.
        const wf = run.workflowName.isNull
            ? (run.name.isNull ? "" : run.name.get)
            : run.workflowName.get;

        // Paginate the jobs endpoint (SPEC §6.1): a large matrix can exceed one page.
        GhJob[] runJobs;
        int jobsPage = 1;
        bool runFailed = false;
        while (true)
        {
            string jobsUrl = "https://api.github.com/repos/" ~ opts.repo
                ~ "/actions/runs/" ~ run.id.to!string
                ~ "/jobs?per_page=" ~ perPage.to!string ~ "&page=" ~ jobsPage.to!string;

            auto jr = fetchJson!GhJobsResponse(jobsUrl, "GET", null, makeAuthHeaders(authHeader));
            if (jr.hasError)
            {
                runFailed = true;
                break;
            }

            runJobs ~= jr.value.jobs;
            if (jr.value.jobs.length < perPage)
                break;
            ++jobsPage;
        }

        if (runFailed)
        {
            ++failedRuns;
            tasks.output(jobsId).writeStyled(i"warning: failed jobs for run $(run.id)");
            continue;
        }

        foreach (ghJob; runJobs)
        {
            Duration dur;
            if (!ghJob.startedAt.isNull && !ghJob.completedAt.isNull)
            {
                try
                {
                    auto start = SysTime.fromISOExtString(ghJob.startedAt.get);
                    auto end = SysTime.fromISOExtString(ghJob.completedAt.get);
                    dur = end - start;
                }
                catch (Exception) { /* ignore bad timestamp */ }
            }

            string rname = ghJob.runnerName.isNull ? "" : ghJob.runnerName.get;
            string concl = ghJob.conclusion.isNull ? "" : ghJob.conclusion.get;

            allJobs ~= Job(
                name: ghJob.name,
                workflow: wf,
                duration: dur,
                labels: ghJob.labels,
                runnerName: rname,
                conclusion: concl,
            );
        }

        tasks.output(jobsId).writeStyled(i"$(i + 1) / $(runs.length) runs");

        // Live summary of current aggregates (range pipeline)
        auto currentPositive = jobsWithDuration(allJobs);
        auto currentBy = aggregateByRunner(currentPositive);
        {
            auto w = tasks.output(jobsId);
            w.put("runners: ");
            bool first = true;
            foreach (r; currentBy)
            {
                if (!first) w.put(", ");
                first = false;
                w.put(r.runnerType);
                w.put(":");
                writeInteger(w, r.stats.count);
            }
            if (first) w.put("-");
        }
    }

    // Graduate a persistent summary via succeed's detail (the ephemeral tail is
    // cleared on completion). Surface any incomplete-data warning on a follow-up line.
    string jobsDetail = text(jobsWithDuration(allJobs).walkLength, " jobs with duration");
    if (failedRuns > 0)
        jobsDetail ~= text("\n⚠ ", failedRuns, " run(s) failed to fetch — stats may be incomplete");
    tasks.succeed(jobsId, jobsDetail);

    // 3. Pure pipeline processing.
    // No workflow re-filter here: runs were already filtered on name/path at fetch
    // time (SPEC §3), and Job.workflow holds only the display name.
    auto filtered = jobsWithDuration(allJobs).array;

    if (opts.conclusionFilter.length)
        filtered = filtered.filter!(j => j.conclusion == opts.conclusionFilter).array;

    auto overall = computeStats(filtered);
    auto byRunner = aggregateByRunner(filtered);
    auto slowJobs = topSlowJobs(filtered, 5);

    // 4. Render with live-style final output (for now static tables; live during fetch above)
    renderReport(overall, byRunner, slowJobs, theme);

    return success(Report(overall, byRunner, slowJobs));
}

struct Report
{
    JobStats overall;
    RunnerAggregate[] byRunner;
    Job[] slowJobs;
}
