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

import sparkles.base.term_caps : detectTermCaps;
import sparkles.ui.components.live : stdoutLiveRegion;
import sparkles.ui.components.table : drawTable, drawTableLines, TableProps;
import sparkles.ui.components.tasklist : TaskReporter;
import sparkles.ui.components.theme : makeTheme, Theme;

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
    /// The run's `head_branch` — the dimension a regression hunt splits on
    /// ("is this branch slower than `main`, or is the whole repo slower?").
    string branch;
    /// When the job started. The dimension a "slower than before" hunt
    /// actually splits on: a workflow that only triggers on `pull_request`
    /// never produces runs on `main`, so a branch comparison has no baseline
    /// and time is the only axis both populations share.
    SysTime startedAt;
    /// Per-step timings, in the order GitHub reports them. Populated only
    /// under `--steps`: it is the breakdown that says *where* inside a job
    /// the time went, which the job total alone cannot.
    Step[] steps;
}

/// One step of a job, with the wall-clock it occupied.
struct Step
{
    string name;
    Duration duration;
    string conclusion;
}

/// Per-name aggregate — of jobs (`--by-job`) or of steps (`--steps`).
/// The label is whatever was grouped on; `branch` is empty for an
/// undifferentiated group and set when the group is one side of a comparison.
struct NamedAggregate
{
    string label;
    string branch;
    JobStats stats;
}

/// One row of a two-window comparison: the same label measured on a baseline
/// and on a candidate, with the median shift between them.
struct Comparison
{
    string label;
    JobStats baseline;
    JobStats candidate;

    /// Signed median difference, candidate − baseline. Duration is signed, so
    /// a speed-up is simply negative.
    Duration delta() const @safe pure nothrow @nogc
        => candidate.median - baseline.median;

    /// `delta` as a percentage of the baseline median, or `double.nan` when
    /// there is no baseline to be a percentage of.
    double deltaPercent() const @safe pure nothrow @nogc
    {
        const base = baseline.median.total!"msecs";
        return base == 0 ? double.nan : 100.0 * delta.total!"msecs" / base;
    }
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
    // Nullable for the same reason: a run triggered outside a branch context
    // (a tag push, a scheduled run on a deleted ref) reports null.
    @WireName("head_branch") Nullable!string headBranch;
}

struct GhRunsResponse
{
    long total_count;
    @WireName("workflow_runs") GhWorkflowRun[] workflowRuns;
}

struct GhStep
{
    string name;
    Nullable!string conclusion;
    @WireName("started_at") Nullable!string startedAt;
    @WireName("completed_at") Nullable!string completedAt;
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
    // Absent on a job that never started; the jobs endpoint returns it inline,
    // so a step breakdown costs no extra request.
    GhStep[] steps;
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
            return failure!T("JSON decode error: " ~ decoded.error.toString);

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

/// Group a range by a caller-supplied key and compute `JobStats` per group,
/// heaviest group first. The one grouping primitive behind `--by-job`,
/// `--steps`, and the two sides of `--baseline`; `aggregateByRunner` predates
/// it and keeps its own shape.
NamedAggregate[] aggregateBy(alias keyOf, R)(R items)
{
    import std.algorithm.sorting : sort;

    auto keyed = items
        .map!(x => tuple(keyOf(x), x))
        .array
        .sort!((a, b) => a[0] < b[0])
        .release;

    NamedAggregate[] result;
    if (keyed.empty)
        return result;

    string currentKey = keyed.front[0];
    auto group = [keyed.front[1]];
    foreach (t; keyed.drop(1))
    {
        if (t[0] != currentKey)
        {
            result ~= NamedAggregate(currentKey, "", computeStats(group));
            currentKey = t[0];
            group = [t[1]];
        }
        else
            group ~= t[1];
    }
    result ~= NamedAggregate(currentKey, "", computeStats(group));

    result.sort!((a, b) => a.stats.total > b.stats.total);
    return result;
}

/// Per-job-name aggregate: which named job owns the wall-clock.
NamedAggregate[] aggregateByJobName(R)(R jobs)
if (isInputRange!R && is(ElementType!R == Job))
    => aggregateBy!(j => j.name)(jobs);

/// Per-step aggregate within one job name. Steps are keyed by name alone:
/// a matrix runs the same step list on every leg, and the interesting figure
/// is the step's typical cost across them.
NamedAggregate[] aggregateByStep(R)(R jobs)
if (isInputRange!R && is(ElementType!R == Job))
    => aggregateBy!(s => s.name)(jobs.map!(j => j.steps).join);

/// Match per-label aggregates from two populations into comparison rows,
/// heaviest candidate first. A label present on only one side still yields a
/// row — with `JobStats.init` for the missing side — because "this job only
/// exists on the new branch" is itself an answer to where the time went.
Comparison[] compareByLabel(NamedAggregate[] baseline, NamedAggregate[] candidate) @safe pure
{
    import std.algorithm.sorting : sort;

    JobStats[string] base;
    foreach (b; baseline)
        base[b.label] = b.stats;

    Comparison[] rows;
    bool[string] seen;
    foreach (c; candidate)
    {
        seen[c.label] = true;
        rows ~= Comparison(c.label, base.get(c.label, JobStats.init), c.stats);
    }
    foreach (b; baseline)
        if (b.label !in seen)
            rows ~= Comparison(b.label, b.stats, JobStats.init);

    rows.sort!((a, b) => a.candidate.total > b.candidate.total);
    return rows;
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

/// A signed percentage with an explicit sign and one decimal (`+34.2%`), or
/// `n/a` when there is no baseline to compare against.
string fmtDeltaPercent(double pct)
{
    import std.math : isNaN, abs;

    if (pct.isNaN)
        return "n/a";
    ulong scaled = cast(ulong)(pct.abs * 10.0 + 0.5);
    SmallBuffer!(char, 24) buf;
    buf ~= pct < 0 ? '-' : '+';
    writeFixedPoint(buf, scaled, 1);
    buf ~= '%';
    return buf[].idup;
}

/// A signed duration (`+2.4m`). `writeDuration` renders magnitudes, so the
/// sign is carried explicitly and the value passed as its absolute.
string fmtDeltaDuration(Duration d)
{
    SmallBuffer!(char, 32) buf;
    buf ~= d < Duration.zero ? '-' : '+';
    writeDuration(buf, d < Duration.zero ? -d : d);
    return buf[].idup;
}

void renderByLabel(in NamedAggregate[] rows, string title)
{
    import sparkles.ui.components.table : drawTable, TableProps;

    if (rows.empty)
        return;

    string[][] table = [["Name", "Runs", "Total", "Median", "Min", "Max"]];
    foreach (r; rows)
        table ~= [
            r.label,
            fmtCount(r.stats.count),
            fmtDur(r.stats.total),
            fmtDur(r.stats.median),
            fmtDur(r.stats.min),
            fmtDur(r.stats.max),
        ];

    writeln();
    writeln(drawTable(table, TableProps(headerRows: 1, title: title)));
}

void renderComparison(in Comparison[] rows, string baselineLabel, string candidateLabel)
{
    import sparkles.ui.components.table : drawTable, TableProps;

    if (rows.empty)
        return;

    // Medians, not totals: the two sides almost never have the same run count,
    // so a total comparison would mostly measure how often each ref was pushed.
    string[][] table = [
        ["Name", baselineLabel ~ " (n)", "median", candidateLabel ~ " (n)", "median", "Δ", "Δ%"]
    ];
    foreach (r; rows)
        table ~= [
            r.label,
            fmtCount(r.baseline.count),
            r.baseline.count ? fmtDur(r.baseline.median) : "-",
            fmtCount(r.candidate.count),
            r.candidate.count ? fmtDur(r.candidate.median) : "-",
            (r.baseline.count && r.candidate.count) ? fmtDeltaDuration(r.delta) : "-",
            (r.baseline.count && r.candidate.count) ? fmtDeltaPercent(r.deltaPercent) : "-",
        ];

    writeln();
    writeln(drawTable(table, TableProps(headerRows: 1, title: "Per-job median: " ~ candidateLabel ~ " vs " ~ baselineLabel)));
}

void renderReport(in JobStats overall, in RunnerAggregate[] byRunner, Job[] slowJobs, in Theme theme)
{
    import std.stdio : writeln;
    import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;

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
    /// Restrict to runs whose `head_branch` matches exactly.
    string branchFilter;
    /// Branch to compare `branchFilter` against, per job name. Each ref is
    /// fetched with its own `--limit`, since one recency window is dominated
    /// by whichever ref was pushed last.
    ///
    /// Only meaningful when both refs actually run the workflow. A
    /// `pull_request`-triggered workflow never runs on `main`, so comparing
    /// against `main` yields an empty baseline — use `splitAt` there.
    string baselineBranch;
    /// Split the fetched jobs at this instant and compare the two halves per
    /// job name: before is the baseline, at-or-after the candidate. The axis
    /// that answers "slower than before" without needing two refs.
    string splitAt;
    /// Break the slowest job names down by step.
    bool showSteps;
    /// How many job names to expand under `--steps`.
    int stepJobs = 3;
}

/// The wall-clock between two ISO-8601 instants, or `Duration.zero` when
/// either is absent or unparseable (a step that never ran, a malformed stamp).
Duration spanOf(in Nullable!string from, in Nullable!string to) @safe nothrow
{
    if (from.isNull || to.isNull)
        return Duration.zero;
    try
        return SysTime.fromISOExtString(to.get) - SysTime.fromISOExtString(from.get);
    catch (Exception)
        return Duration.zero;
}

/// Parse a split pivot: a bare `YYYY-MM-DD` (midnight UTC) or a full ISO-8601
/// instant. The bare-date form is what a person types, and matching `--since`'s
/// accepted shape keeps the two flags interchangeable in a command line.
SysTime parseSplitInstant(string s) @safe
{
    import std.exception : enforce;

    enforce(s.length >= 10, "expected YYYY-MM-DD or an ISO-8601 instant, got '" ~ s ~ "'");
    return SysTime.fromISOExtString(s.length == 10 ? s ~ "T00:00:00Z" : s);
}

@("ci_stats.parseSplitInstant.bareDateIsMidnightUtc")
@safe unittest
{
    assert(parseSplitInstant("2026-08-05") == SysTime.fromISOExtString("2026-08-05T00:00:00Z"));
    assert(parseSplitInstant("2026-08-05T12:30:00Z")
        == SysTime.fromISOExtString("2026-08-05T12:30:00Z"));
}

@("ci_stats.compareByLabel.oneSidedLabelsSurvive")
@safe unittest
{
    // A job that exists on only one side is itself a finding, so it must not
    // be dropped — it renders with an empty count on the missing side.
    auto rows = compareByLabel(
        [NamedAggregate("gone", "", JobStats(count: 2))],
        [NamedAggregate("new", "", JobStats(count: 3))],
    );
    assert(rows.length == 2);
    assert(rows[0].label == "new" && rows[0].baseline.count == 0);
    assert(rows[1].label == "gone" && rows[1].candidate.count == 0);
}

Step[] toSteps(in GhStep[] steps) @safe nothrow
{
    Step[] result;
    foreach (s; steps)
        result ~= Step(
            name: s.name,
            duration: spanOf(s.startedAt, s.completedAt),
            conclusion: s.conclusion.isNull ? "" : s.conclusion.get,
        );
    return result;
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
    const perPage = 100;
    string baseUrl = "https://api.github.com/repos/" ~ opts.repo ~ "/actions/runs";

    // A comparison needs a *balanced* window. Runs come back created-desc, so
    // one shared window is dominated by whichever ref was pushed most recently
    // — asking for 120 runs while iterating on a branch returned 24 runs for
    // the branch and zero for `main`, making every delta unmeasurable. Fetch
    // each ref separately (the API filters server-side on `branch=`) so both
    // sides get `--limit` runs of their own.
    string[] refsToFetch = opts.baselineBranch.length
        ? [opts.branchFilter, opts.baselineBranch]
        : [opts.branchFilter];  // a single "" element means unfiltered

    foreach (wantRef; refsToFetch)
    {
    const target = runs.length + opts.limit;
    int page = 1;
    while (runs.length < target)
    {
        string url = baseUrl ~ "?per_page=" ~ perPage.to!string ~ "&page=" ~ page.to!string;
        if (opts.since.length)
            url ~= "&created=" ~ encodeComponent(">=" ~ opts.since);
        if (wantRef.length)
            url ~= "&branch=" ~ encodeComponent(wantRef);

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
            if (runs.length >= target)
                break;
        }

        tasks.output(runsId).writeStyled(i"$(runs.length) runs so far");

        // Break on the RAW page length — a short *filtered* page is not the last page.
        if (rawPage.length < perPage)
            break;
        ++page;
    }
    }

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
            const dur = spanOf(ghJob.startedAt, ghJob.completedAt);
            SysTime started;
            if (!ghJob.startedAt.isNull)
                try
                    started = SysTime.fromISOExtString(ghJob.startedAt.get);
                catch (Exception) { /* leave unset; the split treats it as oldest */ }

            string rname = ghJob.runnerName.isNull ? "" : ghJob.runnerName.get;
            string concl = ghJob.conclusion.isNull ? "" : ghJob.conclusion.get;

            allJobs ~= Job(
                name: ghJob.name,
                workflow: wf,
                duration: dur,
                labels: ghJob.labels,
                runnerName: rname,
                conclusion: concl,
                branch: run.headBranch.isNull ? "" : run.headBranch.get,
                startedAt: started,
                steps: opts.showSteps ? toSteps(ghJob.steps) : null,
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

    // 5. Regression views. `--baseline` splits the same window into two
    // populations and compares them per job name; without it, the per-job
    // table is still the first thing to look at, since the overall total
    // hides which named job moved.
    auto byJob = aggregateByJobName(filtered);
    Comparison[] comparison;

    // Which axis splits the population in two — time, branch, or neither.
    bool delegate(in Job) @safe isCandidate;
    string baseLabel, candLabel;

    if (opts.splitAt.length)
    {
        SysTime pivot;
        try
            pivot = parseSplitInstant(opts.splitAt);
        catch (Exception e)
            return failure!Report("--split: " ~ e.msg);

        isCandidate = (in Job j) => j.startedAt >= pivot;
        baseLabel = "before " ~ opts.splitAt;
        candLabel = "since " ~ opts.splitAt;
    }
    else if (opts.baselineBranch.length)
    {
        isCandidate = (in Job j) => j.branch == opts.branchFilter;
        baseLabel = opts.baselineBranch;
        candLabel = opts.branchFilter;
    }

    if (isCandidate is null)
        renderByLabel(byJob, "By Job Name");
    else
    {
        auto baseJobs = filtered.filter!(j => !isCandidate(j)).array;
        auto candJobs = filtered.filter!(j => isCandidate(j)).array;
        comparison = compareByLabel(aggregateByJobName(baseJobs), aggregateByJobName(candJobs));
        renderComparison(comparison, baseLabel, candLabel);
    }

    if (opts.showSteps)
        foreach (agg; byJob.take(opts.stepJobs))
        {
            auto jobsOfName = filtered.filter!(j => j.name == agg.label).array;
            if (isCandidate is null)
                renderByLabel(aggregateByStep(jobsOfName), "Steps of " ~ agg.label);
            else
                renderComparison(
                    compareByLabel(
                        aggregateByStep(jobsOfName.filter!(j => !isCandidate(j))),
                        aggregateByStep(jobsOfName.filter!(j => isCandidate(j))),
                    ),
                    baseLabel,
                    candLabel ~ " — " ~ agg.label,
                );
        }

    return success(Report(overall, byRunner, slowJobs, byJob, comparison));
}

struct Report
{
    JobStats overall;
    RunnerAggregate[] byRunner;
    Job[] slowJobs;
    NamedAggregate[] byJob;
    Comparison[] comparison;
}
