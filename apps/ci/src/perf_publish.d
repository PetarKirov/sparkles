/++
Publishing run records to `refs/perf/data` (observability OD21; `apps/ci`
PLAN M3a): CI's append of a validating run's records (OBH4–OBH5), a
maintainer's push of local records (OBH6), and an importer that seeds the
history from an earlier CI run's job logs.

The appender never trusts a record's own claims about which run it belongs
to: the workflow reads the run's identity and date from the provider's API and
passes them here, and every record must carry that run's identifier prefix.
+/
module perf_publish;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join, split;
import std.conv : to;
import std.file : dirEntries, exists, isDir, readText, SpanMode;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName, expandTilde, relativePath;
import std.string : indexOf, lineSplitter, strip;

import sparkles.base.expected : Expected, err, ok;

import perf_history : Append, appendRecords, historyCacheDir, RecordFiles, recordsPerJob, validateRecord;
import perf_record : encodeRecord, githubRunId, localRecordsRoot, RecordedTask, RunFacts, TaskOutcome, testTaskId,
    writeRecord;

/// The repository a maintainer pushes the history to: over SSH, with their key.
enum pushRemote = "git@github.com:PetarKirov/sparkles.git";

/// Every record directory under `root`: those holding a `run.json`.
RecordFiles[] collectRecords(string root) @trusted
{
    RecordFiles[] records;
    if (!exists(root) || !isDir(root))
        return records;
    foreach (entry; dirEntries(root, "run.json", SpanMode.depth))
    {
        const dir = entry.name.dirName;
        RecordFiles r;
        r.runId = dir.baseName;
        foreach (f; dirEntries(dir, SpanMode.depth))
            if (f.isFile)
                r.files[relativePath(f.name, dir).split("\\").join("/")] = readText(f.name);
        records ~= r;
    }
    records.sort!((a, b) => a.runId < b.runId);
    return records;
}

/**
The records of one CI run that may be appended (OBH5): each valid, of run
`runId` and of one of its attempts up to `lastAttempt`, the first of any
identifier claimed twice, and at most `recordsPerJob` per job. A re-run of
the failed jobs keeps the passed jobs' artifacts, so one run's records carry
the attempts that wrote them. `dropped` says why each other one was left out.
*/
RecordFiles[] admitRunRecords(RecordFiles[] records, string runId, uint lastAttempt, out string[] dropped) @safe
{
    RecordFiles[] admitted;
    bool[string] seen;
    uint[string] perJob;
    foreach (r; records)
    {
        if (const why = validateRecord(r, "gh-" ~ runId ~ "-"))
        {
            dropped ~= r.runId ~ ": " ~ why;
            continue;
        }
        const parts = r.runId.split("-");
        if (parts.length != 5)
        {
            dropped ~= r.runId ~ ": not gh-<run>-<attempt>-<job>-<n>";
            continue;
        }
        // `gh-<run>-<attempt>-<job>-<n>`: the attempt is the third segment.
        const attempt = parts[2];
        if (!attemptAtMost(attempt, lastAttempt))
        {
            dropped ~= r.runId ~ format(": attempt %s is not one of the run's %d", attempt, lastAttempt);
            continue;
        }
        if (r.runId in seen)
        {
            dropped ~= r.runId ~ ": a second record claims this identifier";
            continue;
        }
        // `gh-<run>-<attempt>-<job>-<n>`: the job is the fourth segment.
        const job = parts[3];
        if (perJob.get(job, 0) >= recordsPerJob)
        {
            dropped ~= r.runId ~ format(": more than %d records for job %s", recordsPerJob, job);
            continue;
        }
        seen[r.runId] = true;
        perJob[job] = perJob.get(job, 0) + 1;
        admitted ~= r;
    }
    return admitted;
}

@("perfPublish.admitRunRecords.bounds")
@safe
unittest
{
    RecordFiles rec(string id) => RecordFiles(id, ["run.json":
        `{"schema":"sparkles.perf.run","version":1,"run":"` ~ id ~ `","origin":"ci"}`]);
    string[] dropped;
    auto admitted = admitRunRecords([
        rec("gh-9-1-aaaaaaaaaaaa-1"), rec("gh-9-1-aaaaaaaaaaaa-2"), rec("gh-9-1-aaaaaaaaaaaa-3"),
        rec("gh-9-1-aaaaaaaaaaaa-4"), rec("gh-9-1-aaaaaaaaaaaa-5"), rec("gh-9-1-aaaaaaaaaaaa-1"),
        rec("gh-9-1-bbbbbbbbbbbb-1"), rec("gh-8-1-bbbbbbbbbbbb-1"),
        // A re-run of the failed jobs: its record says attempt 3, the others 1.
        rec("gh-9-3-cccccccccccc-1"), rec("gh-9-4-cccccccccccc-1"), rec("gh-9-0-cccccccccccc-1"),
    ], "9", 3, dropped);
    assert(admitted.map!(r => r.runId).array == ["gh-9-1-aaaaaaaaaaaa-1", "gh-9-1-aaaaaaaaaaaa-2",
        "gh-9-1-aaaaaaaaaaaa-3", "gh-9-1-aaaaaaaaaaaa-4", "gh-9-1-bbbbbbbbbbbb-1", "gh-9-3-cccccccccccc-1"]);
    assert(dropped.length == 5,
        "a fifth for one job, a repeated id, another run's record, attempts 4 and 0 of a run at 3");
}

/// Whether `text` is a run attempt from 1 to `last`.
private bool attemptAtMost(string text, uint last) @safe pure nothrow
{
    if (text.length == 0 || text.length > 9)
        return false;
    uint n;
    foreach (c; text)
    {
        if (c < '0' || c > '9')
            return false;
        n = n * 10 + (c - '0');
    }
    return n >= 1 && n <= last;
}

/// The run directory of a record in the history (OBH1).
string runDir(string dateUtc, string commit, string runId) @safe pure
in (dateUtc.length >= 10 && commit.length >= 12)
{
    return format("runs/%s/%s/%s/%s-%s", dateUtc[0 .. 4], dateUtc[5 .. 7], dateUtc[8 .. 10], commit[0 .. 12], runId);
}

/**
`ci perf append`: append the records under `recordsRoot`, downloaded from the
artifacts of run `runId`, attempt `attempt`, which started on `runDate`, under
the landed commit `landedCommit` (OBH4). The identity and date are the
provider's, never the records' (OBH5).
*/
Expected!(string, string) appendRun(string recordsRoot, string runId, string attempt, string runDate,
    string landedCommit, string signingKey, string remote, string signersFile) @trusted
{
    string[] dropped;
    auto records = collectRecords(recordsRoot);
    uint lastAttempt;
    try
        lastAttempt = attempt.to!uint;
    catch (Exception)
        return err!string("--run-attempt " ~ attempt ~ " is not a number");
    auto admitted = admitRunRecords(records, runId, lastAttempt, dropped);
    string report;
    foreach (d; dropped)
        report ~= "dropped " ~ d ~ "\n";
    // Records that all fail admission are a fault to see, not an empty run.
    if (admitted.length == 0 && records.length > 0)
        return err!string(report ~ format("every one of the %d record(s) was dropped", records.length));
    if (admitted.length == 0)
        return ok(report ~ "no record to append");
    Append[] appends = admitted.map!(r => Append(runDir(runDate, landedCommit, r.runId), r)).array;
    const done = appendRecords(historyCacheDir(remote), remote, signersFile, appends, signingKey,
        format("append %d record(s) of run %s attempt %s for %s", appends.length, runId, attempt,
            landedCommit[0 .. 12]));
    if (done.hasError)
        return err!string(report ~ done.error);
    return ok(report ~ format("appended %d record(s), %d already present", done.value.length,
        appends.length - done.value.length));
}

/**
`ci perf push`: append this machine's records, signed with the maintainer's
key (OBH6). A record of a dirty tree is refused unless `allowDirty`; a record
from CI is never pushed from here.
*/
Expected!(string, string) pushLocal(bool allowDirty, string signingKey, string remote, string signersFile) @trusted
{
    string report;
    Append[] appends;
    foreach (r; collectRecords(localRecordsRoot()))
    {
        if (const why = validateRecord(r, ""))
        {
            report ~= "skipped " ~ r.runId ~ ": " ~ why ~ "\n";
            continue;
        }
        auto run = parseJSON(r.files["run.json"]);
        const origin = run["origin"].str;
        if (origin != "local" && origin != "imported")
        {
            report ~= "skipped " ~ r.runId ~ ": a record of origin " ~ origin ~ " is CI's to append\n";
            continue;
        }
        const dirty = "source" in run && "dirty" in run["source"] && run["source"]["dirty"].boolean;
        if (dirty && !allowDirty)
        {
            report ~= "skipped " ~ r.runId ~ ": measured a dirty tree (--allow-dirty pushes it)\n";
            continue;
        }
        const commit = "source" in run && "commit" in run["source"] ? run["source"]["commit"].str : "";
        if (commit.length < 12)
        {
            report ~= "skipped " ~ r.runId ~ ": no commit\n";
            continue;
        }
        appends ~= Append(runDir(run["start"].str, commit, r.runId), r);
    }
    {
        import perf_pr : localPrAppends;

        appends ~= localPrAppends(report); // the records `ci perf import-prs` wrote (OBQ9)
    }
    if (appends.length == 0)
        return ok(report ~ "nothing to push");
    const done = appendRecords(historyCacheDir(remote), remote, signersFile, appends, signingKey,
        format("push %d local record(s)", appends.length));
    if (done.hasError)
        return err!string(report ~ done.error);
    return ok(report ~ format("pushed %d record(s), %d already present", done.value.length,
        appends.length - done.value.length));
}

/// The signing key git is configured with, `~` expanded.
string configuredSigningKey(string repoRoot) @trusted
{
    import sparkles.build_primitives.git_env : runGitStdout;

    const r = runGitStdout(["config", "user.signingkey"], workDir: repoRoot);
    return r.status == 0 ? r.output.strip.expandTilde : null;
}

// ── importing a run's logs ────────────────────────────────────────────────

/// What a GitHub job's name says about its placement and shard, for the
/// importer: `test (x86_64-linux, ldc2, 1/2)`, `Sanitizers (ASan, stackovf)
/// (1/2)`, `Extracted test modes (--better-c, --wasm)`, and the placement
/// jobs' own `test (x86_64-linux-ldc2, 1/2)`. Null for any other job.
string[2] placementOfJob(string jobName) @safe pure
{
    string inner(string s)
    {
        const open = s.indexOf('(');
        const close = s.lastIndexOfChar(')');
        return open >= 0 && close > open ? s[open + 1 .. close] : null;
    }

    if (jobName.startsWith("Extracted test modes"))
        return ["x86_64-linux-extracted", "1/1"];
    if (jobName.startsWith("Sanitizers"))
    {
        const last = jobName[jobName.lastIndexOfChar('(') .. $];
        const shard = last.canFind("/") ? inner(last) : "1/1";
        return ["x86_64-linux-sanitize", shard];
    }
    if (!jobName.startsWith("test ("))
        return [null, null];
    auto parts = inner(jobName).split(", ");
    if (parts.length == 2 && parts[1].canFind("/"))
        return [parts[0], parts[1]]; // the placement jobs' own names
    if (parts.length == 3 && parts[2].canFind("/"))
        return [parts[0] ~ "-" ~ parts[1], parts[2]];
    if (parts.length == 4)
        return [parts[1] ~ "-" ~ parts[2], "1/1"]; // unsharded: (runner, system, DC, timeout)
    return [null, null];
}

private ptrdiff_t lastIndexOfChar(string s, char c) @safe pure nothrow @nogc
{
    foreach_reverse (i, ch; s)
        if (ch == c)
            return i;
    return -1;
}

@("perfPublish.placementOfJob.names")
@safe pure
unittest
{
    assert(placementOfJob("test (x86_64-linux, ldc2, 1/2)") == ["x86_64-linux-ldc2", "1/2"]);
    assert(placementOfJob("test (aarch64-linux-ldc2, 3/3)") == ["aarch64-linux-ldc2", "3/3"]);
    assert(placementOfJob("test (ubuntu-latest, x86_64-linux, dmd, 75)") == ["x86_64-linux-dmd", "1/1"]);
    assert(placementOfJob("Sanitizers (ASan, stackovf) (2/2)") == ["x86_64-linux-sanitize", "2/2"]);
    assert(placementOfJob("Sanitizers (ASan, stackovf)") == ["x86_64-linux-sanitize", "1/1"]);
    assert(placementOfJob("Extracted test modes (--better-c, --wasm)") == ["x86_64-linux-extracted", "1/1"]);
    assert(placementOfJob("Lint & markdown link check")[0] is null);
}

/**
The tasks a `ci test` job log (ordinary, `--sanitize address` or `--special-modes`)
holds: each top-level `╭──╼ [i/N] <package> › dub test :<package> -- <args>`
box and the `Δtᵢ` of the `╰──╼` line that closes it. `-t 1` is the serial
leg; `--better-c` and `--wasm` are the extracted modes.
*/
RecordedTask[] tasksFromLog(string log, bool sanitize) @safe
{
    import std.regex : ctRegex, matchFirst, replaceAll;

    enum ansi = ctRegex!(`(\x1b|\^\[)\[[0-9;]*m`);
    enum open = ctRegex!(`^╭──╼ \[\d+/\d+\] (\S+) › dub test :\S+ -- (.*?) ╾`);
    enum close = ctRegex!(`^╰──╼ (✓|✗).*Δtᵢ +([0-9.]+)(ms|µs|s|m|h)`);

    RecordedTask[] tasks;
    string pkg, args;
    ulong clock;
    foreach (raw; log.lineSplitter)
    {
        auto line = raw.replaceAll(ansi, "");
        // `<job>\t<step>\t<timestamp> <text>` in a downloaded job log: keep the text.
        foreach (_; 0 .. 2)
        {
            const tab = line.indexOf('\t');
            if (tab >= 0)
                line = line[tab + 1 .. $];
        }
        const space = line.indexOf(' ');
        if (space > 0 && line[0 .. space].endsWith("Z") && line[0 .. space].canFind("T"))
            line = line[space + 1 .. $];
        if (auto m = line.matchFirst(open))
        {
            pkg = m[1];
            args = m[2];
            continue;
        }
        if (pkg.length)
            if (auto m = line.matchFirst(close))
            {
                const v = m[2].to!double;
                const ns = cast(ulong) (v * (m[3] == "ms" ? 1e6 : m[3] == "µs" ? 1e3 : m[3] == "s" ? 1e9
                    : m[3] == "m" ? 60e9 : 3600e9));
                string id;
                if (args.canFind("--better-c"))
                    id = testTaskId(pkg, "betterc", true);
                else if (args.canFind("--wasm"))
                    id = testTaskId(pkg, "wasm", true);
                else
                    id = testTaskId(pkg, sanitize ? "sanitize" : "unittest", args.strip.startsWith("-t 1 ")
                        || args.strip == "-t 1");
                tasks ~= RecordedTask(id, m[1] == "✓" ? TaskOutcome.passed : TaskOutcome.failed, clock, clock + ns);
                clock += ns;
                pkg = null;
            }
    }
    return tasks;
}

@("perfPublish.tasksFromLog.boxes")
@safe
unittest
{
    enum log = "test\tBuild\t2026-11-16T10:00:00.0000000Z ╭──╼ [1/2] base › dub test :base -- -t 1 ╾──╮\n"
        ~ "test\tBuild\t2026-11-16T10:00:01.0000000Z │ ✓ inner test\n"
        ~ "test\tBuild\t2026-11-16T10:00:09.0000000Z ╰──╼ ✓ passed ╾──╼ Δt 9.0s | Δtᵢ  2.5s (usr 1s) ╾──╯\n"
        ~ "test\tBuild\t2026-11-16T10:00:10.0000000Z ╭──╼ [1/2] base › dub test :base -- -t 3 ╾──╮\n"
        ~ "test\tBuild\t2026-11-16T10:00:11.0000000Z ╰──╼ ✗ FAILED ╾──╼ Δt 1.2m | Δtᵢ 1.5m ╾──╯\n";
    const tasks = tasksFromLog(log, false);
    assert(tasks.length == 2);
    assert(tasks[0].id == "test:base:unittest:serial" && tasks[0].wallNs == 2_500_000_000);
    assert(tasks[1].id == "test:base:unittest:parallel" && tasks[1].outcome == TaskOutcome.failed
        && tasks[1].wallNs == 90_000_000_000);
}

/**
`ci perf import RUN`: build a record per test job of GitHub Actions
run `RUN` from its logs, with `gh`, under this machine's records as origin
`imported`, for `ci perf push` to publish. Returns a report of what it wrote.
*/
Expected!(string, string) importGithubRun(string repo, string run) @trusted
{
    import sparkles.core_cli.process_utils : runCaptured;
    import perf_run : currentProducer;

    const meta = runCaptured(["gh", "api", "repos/" ~ repo ~ "/actions/runs/" ~ run]);
    if (!meta.succeeded)
        return err!string("cannot read run " ~ run ~ ": " ~ meta.stderr.strip);
    auto runJson = parseJSON(meta.stdout);
    const attempt = runJson["run_attempt"].integer.to!string;
    const headSha = runJson["head_sha"].str;
    const jobs = runCaptured(["gh", "api", "--paginate", "repos/" ~ repo ~ "/actions/runs/" ~ run
        ~ "/attempts/" ~ attempt ~ "/jobs", "--jq", ".jobs[] | [.id, .name, .started_at, .conclusion] | @tsv"]);
    if (!jobs.succeeded)
        return err!string("cannot list the jobs of run " ~ run ~ ": " ~ jobs.stderr.strip);

    string report;
    foreach (line; jobs.stdout.lineSplitter)
    {
        const cols = line.split("\t");
        if (cols.length < 4)
            continue;
        const placement = placementOfJob(cols[1]);
        if (placement[0] is null)
            continue;
        const log = runCaptured(["gh", "api", "repos/" ~ repo ~ "/actions/jobs/" ~ cols[0] ~ "/logs"]);
        if (!log.succeeded)
        {
            report ~= "no log for " ~ cols[1] ~ "\n";
            continue;
        }
        const tasks = tasksFromLog(log.stdout, placement[0].canFind("sanitize"));
        if (tasks.length == 0)
            continue;
        RunFacts f;
        f.commit = headSha;
        f.provider = "github";
        f.placement = placement[0];
        f.shard = placement[1];
        f.os = placement[0].canFind("darwin") ? "darwin" : "linux";
        f.compiler = placement[0].endsWith("dmd") ? "dmd" : "ldc2";
        f.command = placement[0].canFind("sanitize") ? "test --sanitize address"
            : placement[0].canFind("extracted") ? "test --special-modes" : "test";
        const id = githubRunId(run, attempt, cols[1], 1);
        const start = cols[2].length >= 19 ? cols[2][0 .. 19] ~ "Z" : "1970-01-01T00:00:00Z";
        const files = encodeRecord(id, "imported", start, f, tasks, ["imported from the job log of " ~ cols[1]]);

        const why = writeRecord(localRecordsRoot(), start, id, files, currentProducer("."));
        report ~= why.length ? why ~ "\n" : format("%s: %d task(s) as %s\n", cols[1], tasks.length, id);
    }
    return ok(report);
}
