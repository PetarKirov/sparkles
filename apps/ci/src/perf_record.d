/++
Run records for the current test modes (observability OD21; `apps/ci` PLAN
M3a): one task per package run, with its id, series key, outcome and
`task.wall`, and the facts that exist before the build graph.

A record is a directory (OBD4): `run.json` with the run's identity and facts,
and `tasks/<s>.json` with the tasks whose series key starts with a hexadecimal
digit `d`, where `s` is `d / 2`. Every file is JSON with a fixed member order
and integers only (OBD5). Before a record is written it passes the privacy
scan (OBP4); one that fails is not written, and the failure is a run
degradation, never an outcome (OBD11).

The encoding, the keys and the scan are pure and tested here. Collecting host
facts and writing the directory are the small impure half at the end.
+/
module perf_record;

import std.algorithm.iteration : map;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : Appender, appender, join;
import std.ascii : LetterCase, isAlpha, isAlphaNum;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.format : format;
import std.string : indexOf;

/// The schema `run.json` begins with (OBD6).
enum recordSchema = "sparkles.perf.run";
/// Its version; a reader reads this one and the one before it.
enum recordVersion = 1;

/// A task's outcome, as the test modes see it.
enum TaskOutcome : ubyte
{
    passed,
    failed,
}

/// One task of a record: a package's test run, or a `ci perf record` command.
struct RecordedTask
{
    string id; /// TDM1's form: `test:<package>:<mode>:<leg>`, `pin-build:<pin>`
    TaskOutcome outcome;
    ulong startNs; /// Since the run's start.
    ulong endNs;

    /// `task.wall`, in nanoseconds.
    ulong wallNs() const @safe pure nothrow @nogc => endNs - startNs;
}

/// The lowercase hexadecimal SHA-256 of `text`.
string sha256Hex(in char[] text) @safe pure nothrow
{
    const digest = sha256Of(text);
    return toHexString!(LetterCase.lower)(digest).idup;
}


/**
A task's series key (OBD2): the SHA-256 of its task id. A test task has no
variant key before the build graph, so the id alone names the series.
*/
string seriesKey(string taskId) @safe pure nothrow => sha256Hex(taskId);

/// The shard `tasks/<s>.json` that holds a series key: its first digit, halved.
uint taskShard(string series) @safe pure
in (series.length > 0)
{
    const c = series[0];
    const digit = c <= '9' ? c - '0' : c - 'a' + 10;
    return digit / 2;
}

@("perfRecord.seriesKey.shard")
@safe pure
unittest
{
    const key = seriesKey("test:base:unittest:serial");
    assert(key.length == 64 && key == sha256Hex("test:base:unittest:serial"));
    assert(taskShard("0abc") == 0 && taskShard("1abc") == 0 && taskShard("9abc") == 4);
    assert(taskShard("eabc") == 7 && taskShard("fabc") == 7);
}

/**
A task id for a package test run: `test:<package>:<mode>:<leg>`, where the
mode is `unittest`, `sanitize`, `betterc` or `wasm`, and the leg `serial`
for `-t 1` and `parallel` for every other thread count, so a host with a
different core count continues the series.
*/
string testTaskId(string packageName, string mode, bool serial) @safe pure nothrow =>
    "test:" ~ packageName ~ ":" ~ mode ~ ":" ~ (serial ? "serial" : "parallel");

/**
The run identifier (OBD1). On GitHub Actions: `gh-<run id>-<attempt>-<job>-<n>`,
`<job>` the first twelve hexadecimal digits of the SHA-256 of the job's key
and its matrix values, `<n>` the ordinal of this `ci` invocation in the job.
Elsewhere: `local-` and 32 random hexadecimal digits.
*/
string githubRunId(string runId, string attempt, string jobKeyAndMatrix, uint ordinal) @safe pure nothrow =>
    "gh-" ~ runId ~ "-" ~ attempt ~ "-" ~ sha256Hex(jobKeyAndMatrix)[0 .. 12] ~ "-" ~ ordinal.to!string;

/// Whether `id` is a valid run identifier: lowercase letters, digits and hyphens, at most 64.
bool isRunId(string id) @safe pure nothrow @nogc
{
    if (id.length == 0 || id.length > 64)
        return false;
    foreach (c; id)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
            return false;
    return true;
}

@("perfRecord.runId.forms")
@safe pure nothrow
unittest
{
    const id = githubRunId("43782517554", "2", "test\0x86_64-linux-ldc2\x001/2", 1);
    assert(id.startsWith("gh-43782517554-2-") && id.length == "gh-43782517554-2-".length + 12 + 2);
    assert(isRunId(id));
    assert(!isRunId("gh-1-1-ABC-1") && !isRunId("../x") && !isRunId(""));
}

/// The facts of OBR7 that exist before the build graph. An empty string, or a
/// zero count, is a fact the host could not supply, and is left out (OBV8).
struct RunFacts
{
    // Source
    string commit;
    bool dirty;
    string pullRequest; /// CI only.
    string branch; /// CI only, when not a pull request.
    // Host
    string os;
    string kernel;
    string cpuModel;
    string cpuVendor;
    uint cpuFamily;
    uint cpuModelNumber;
    uint logicalCores;
    uint memoryGiB;
    // Run
    string command; /// `ci test`, `ci test --sanitize address`, …
    string[] options; /// Normalized: only the options that change what runs.
    string compiler; /// `$DC`'s vendor, `ldc2` or `dmd`.
    string compilerVersion;
    string provider; /// `github`, `circleci` or empty for a local run.
    string placement;
    string shard; /// `K/N`, when the run is one shard of a placement.
}

/// A record's comparability key (OBD3): the SHA-256 of the toolchain, the
/// CPU's vendor, family and model, the operating system, and the families.
string comparabilityKey(const RunFacts facts, in string[] families) @safe pure
{
    return sha256Hex(format("%s\0%s\0%s\0%s\0%s\0%-(%s,%)", facts.compilerVersion, facts.cpuVendor,
        facts.cpuFamily, facts.cpuModelNumber, facts.os, families));
}

// ── encoding ───────────────────────────────────────────────────────────────

private void putString(ref Appender!string w, in char[] s) @safe pure
{
    w.put('"');
    foreach (dchar c; s)
    {
        switch (c)
        {
            case '"': w.put(`\"`); break;
            case '\\': w.put(`\\`); break;
            case '\n': w.put(`\n`); break;
            case '\r': w.put(`\r`); break;
            case '\t': w.put(`\t`); break;
            default:
                if (c < 0x20)
                    w.put(format(`\u%04x`, cast(uint) c));
                else
                    w.put(c);
        }
    }
    w.put('"');
}

/// The members of an object, written in the order given: `[key, rendered value]`.
private string jsonObject(in string[2][] members) @safe pure
{
    auto w = appender!string;
    w.put('{');
    foreach (i, m; members)
    {
        if (i)
            w.put(',');
        putString(w, m[0]);
        w.put(':');
        w.put(m[1]);
    }
    w.put('}');
    return w.data;
}

private string str(in char[] s) @safe pure
{
    auto w = appender!string;
    putString(w, s);
    return w.data;
}

private string strings(in string[] list) @safe pure =>
    "[" ~ list.map!(s => str(s)).join(",") ~ "]";

/**
`run.json`: identity, then facts in OBR7's order (source, host, run), then the
degradations. Members a host could not supply are absent, never null.
*/
string encodeRun(string runId, string origin, string startUtc, const RunFacts f, string comparability,
    in string[] degradations) @safe pure
{
    string[2][] source = [["commit", str(f.commit)], ["dirty", f.dirty ? "true" : "false"]];
    if (f.pullRequest.length)
        source ~= ["pullRequest", f.pullRequest];
    else if (f.branch.length)
        source ~= ["branch", str(f.branch)];

    string[2][] host;
    void text(string key, string value) @safe pure
    {
        if (value.length)
            host ~= [key, str(value)];
    }

    void count(string key, uint value) @safe pure
    {
        if (value != 0)
            host ~= [key, value.to!string];
    }

    text("os", f.os);
    text("kernel", f.kernel);
    text("cpuModel", f.cpuModel);
    text("cpuVendor", f.cpuVendor);
    count("cpuFamily", f.cpuFamily);
    count("cpuModelNumber", f.cpuModelNumber);
    count("logicalCores", f.logicalCores);
    count("memoryGiB", f.memoryGiB);

    string[2][] run = [["command", str(f.command)], ["options", strings(f.options)]];
    foreach (m; [["compiler", f.compiler], ["compilerVersion", f.compilerVersion],
            ["provider", f.provider], ["placement", f.placement], ["shard", f.shard]])
        if (m[1].length)
            run ~= [m[0], str(m[1])];

    return jsonObject([
        ["schema", str(recordSchema)],
        ["version", recordVersion.to!string],
        ["run", str(runId)],
        ["origin", str(origin)],
        ["start", str(startUtc)],
        ["comparability", str(comparability)],
        ["families", strings(["process"])],
        ["source", jsonObject(source)],
        ["host", jsonObject(host)],
        ["invocation", jsonObject(run)],
        ["degradations", strings(degradations)],
    ]) ~ "\n";
}

/// `tasks/<s>.json`: the tasks of one shard, in task-id order.
string encodeTasks(in RecordedTask[] tasks) @safe pure
{
    auto sorted = tasks.dup.sort!((a, b) => a.id < b.id).release;
    return jsonObject([
        ["tasks", "[" ~ sorted.map!(t => jsonObject([
            ["id", str(t.id)],
            ["series", str(seriesKey(t.id))],
            ["outcome", str(t.outcome == TaskOutcome.passed ? "passed" : "failed")],
            ["start", t.startNs.to!string],
            ["end", t.endNs.to!string],
            ["metrics", jsonObject([["task.wall", t.wallNs.to!string]])],
        ])).join(",") ~ "]"],
    ]) ~ "\n";
}

/// The record's files, path relative to its directory → content.
string[string] encodeRecord(string runId, string origin, string startUtc, const RunFacts facts,
    in RecordedTask[] tasks, in string[] degradations) @safe pure
{
    string[string] files;
    files["run.json"] = encodeRun(runId, origin, startUtc, facts, comparabilityKey(facts, ["process"]),
        degradations);
    RecordedTask[][8] byShard;
    foreach (t; tasks)
        byShard[taskShard(seriesKey(t.id))] ~= t;
    foreach (s, list; byShard)
        if (list.length)
            files["tasks/" ~ s.to!string ~ ".json"] = encodeTasks(list);
    return files;
}

@("perfRecord.encodeRecord.fixedOrderAndShards")
@safe
unittest
{
    import std.json : parseJSON;

    RunFacts f;
    f.commit = "0123456789abcdef0123456789abcdef01234567";
    f.os = "linux";
    f.logicalCores = 16;
    f.command = "test";
    f.compiler = "ldc2";
    const tasks = [
        RecordedTask("test:ui:unittest:parallel", TaskOutcome.failed, 30, 70),
        RecordedTask("test:base:unittest:serial", TaskOutcome.passed, 0, 25),
    ];
    const files = encodeRecord("local-0123", "local", "2026-11-17T08:00:00Z", f, tasks, []);
    const run = files["run.json"];
    assert(run.startsWith(`{"schema":"sparkles.perf.run","version":1,"run":"local-0123",`), run);
    assert(run.canFind(`"host":{"os":"linux","logicalCores":16}`), "an absent fact is left out");
    assert(run.canFind(`"source":{"commit":"0123456789abcdef0123456789abcdef01234567","dirty":false}`));
    size_t taskCount;
    foreach (path, content; files)
        if (path.startsWith("tasks/"))
        {
            auto parsed = parseJSON(content);
            foreach (t; (() @trusted => parsed["tasks"].array)())
            {
                ++taskCount;
                assert(path == "tasks/" ~ taskShard(t["series"].str).to!string ~ ".json");
                if (t["id"].str == "test:ui:unittest:parallel")
                    assert(t["metrics"]["task.wall"].integer == 40 && t["outcome"].str == "failed");
            }
        }
    assert(taskCount == 2);
}

// ── privacy ────────────────────────────────────────────────────────────────

/// What the producer knows about itself, for the scan's identity rules (OBP4).
struct Producer
{
    string userName;
    string homeLastSegment;
    string hostName;
    string gitEmail;
}

/// `local@domain.tld` somewhere in `s`: a local part right before the `@`, and
/// a dotted domain right after it ending in at least two letters. A CPU name's
/// "CPU @ 2.80GHz" is not one.
private bool looksLikeEmail(in char[] s) @safe pure nothrow
{
    static bool local(char c) => isAlphaNum(c) || c == '.' || c == '_' || c == '%' || c == '+' || c == '-';
    static bool domain(char c) => isAlphaNum(c) || c == '.' || c == '-';
    foreach (at, c; s)
    {
        if (c != '@' || at == 0 || !local(s[at - 1]))
            continue;
        size_t end = at + 1;
        while (end < s.length && domain(s[end]))
            ++end;
        const host = s[at + 1 .. end];
        ptrdiff_t dot = -1;
        foreach (j, h; host[0 .. host.length ? $ - 1 : 0])
            if (h == '.')
                dot = j;
        if (dot <= 0)
            continue;
        const tld = host[dot + 1 .. $];
        bool letters = tld.length >= 2;
        foreach (t; tld)
            letters = letters && isAlpha(t);
        if (letters)
            return true;
    }
    return false;
}

private bool hasForbiddenPath(in char[] s) @safe pure nothrow
{
    foreach (prefix; ["/home/", "/Users/", "/root/", "/tmp/", "/var/", "/etc/", "/opt/", `C:\Users\`, `C:\`])
    {
        const at = s.indexOf(prefix);
        if (at >= 0)
            return true;
    }
    // Any other absolute path: a word starting with `/` that is not a store path.
    size_t i;
    while (i < s.length)
    {
        if (s[i] == '/' && (i == 0 || s[i - 1] == ' ' || s[i - 1] == '"' || s[i - 1] == '='))
            if (!s[i .. $].startsWith("/nix/store/") && i + 1 < s.length && s[i + 1] != ' ')
                return true;
        ++i;
    }
    return false;
}

/**
The privacy scan of OBP4 over every string `content` holds, as JSON. Returns
why it rejects the record, or null. An email, an absolute path that is not a
Nix store path, or a string equal to one of the producer's names, or holding
one as a path segment, rejects it. A repository-relative path is not checked
against the names, so a user named `ci` does not reject every record.
*/
string privacyRejection(string content, in Producer producer) @safe
{
    import std.json : JSONType, JSONValue, parseJSON;

    string reason;
    void visit(const JSONValue v) @safe
    {
        if (reason.length)
            return;
        switch (v.type)
        {
            case JSONType.string:
                const s = v.str;
                if (looksLikeEmail(s))
                    reason = "an email address";
                else if (hasForbiddenPath(s))
                    reason = "an absolute path that is not a Nix store path";
                else if (producer.gitEmail.length && s.canFind(producer.gitEmail))
                    reason = "the producer's git email";
                else
                    foreach (name; [producer.userName, producer.homeLastSegment, producer.hostName])
                        if (name.length && (s == name || (s.startsWith("/") && s.canFind("/" ~ name))))
                            reason = "the producer's user or host name";
                break;
            case JSONType.array:
                foreach (e; (() @trusted => v.array)())
                    visit(e);
                break;
            case JSONType.object:
                foreach (k, e; (() @trusted => v.object)())
                {
                    visit(JSONValue(k));
                    visit(e);
                }
                break;
            default:
                break;
        }
    }

    visit(parseJSON(content));
    return reason;
}

@("perfRecord.privacyRejection.rules")
@safe
unittest
{
    const me = Producer("petar", "petar", "pc2", "someone@example.org");
    assert(privacyRejection(`{"a":"test:base:unittest:serial","b":"libs/base"}`, me) is null);
    assert(privacyRejection(`{"a":"/nix/store/45iz365bm9kwm02x4ll7njn7vfqphq8h-dmd"}`, me) is null);
    assert(privacyRejection(`{"a":"AMD Ryzen 9 7950X 16-Core Processor"}`, me) is null);
    assert(privacyRejection(`{"a":"Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz"}`, me) is null,
        "a CPU name's @ is not an email");
    assert(privacyRejection(`{"a":"x@y.org"}`, me) == "an email address");
    assert(privacyRejection(`{"a":"/home/petar/x"}`, me) !is null);
    assert(privacyRejection(`{"a":"/srv/build"}`, me) !is null, "any absolute path outside the store");
    assert(privacyRejection(`{"a":"pc2"}`, me) == "the producer's user or host name");
    assert(privacyRejection(`{"a":["ok",{"k":"petar"}]}`, me) !is null, "nested strings are scanned");
    const ci = Producer("ci", "ci", "runner", "");
    assert(privacyRejection(`{"a":"apps/ci/src"}`, ci) is null, "a relative path is not checked against names");
}

// ── the impure half ───────────────────────────────────────────────────────

/// The local records directory (OBD12): `$XDG_CACHE_HOME/sparkles/perf/runs`.
string localRecordsRoot() @safe
{
    import std.path : buildPath, expandTilde;
    import std.process : environment;

    const cache = environment.get("XDG_CACHE_HOME", expandTilde("~/.cache"));
    return buildPath(cache, "sparkles", "perf", "runs");
}

/**
Write `files` under `<root>/<yyyy>/<mm>/<dd>/<runId>/` after the privacy scan,
and remove local records older than `keepDays`. Returns the run degradation,
or null when the record was written. Never throws: a failure is reported, it
does not change the run's outcome (OBD11).
*/
string writeRecord(string root, string startUtc, string runId, in string[string] files,
    in Producer producer, uint keepDays = 90) @trusted nothrow
{
    import std.file : dirEntries, mkdirRecurse, rmdirRecurse, SpanMode, timeLastModified, write;
    import std.path : buildPath, dirName;
    import std.datetime.systime : Clock;
    import core.time : days;

    try
    {
        foreach (path, content; files)
        {
            const why = privacyRejection(content, producer);
            if (why.length)
                return format("run record %s not written: %s holds %s", runId, path, why);
        }
        const dir = buildPath(root, startUtc[0 .. 4], startUtc[5 .. 7], startUtc[8 .. 10], runId);
        foreach (path, content; files)
        {
            const full = buildPath(dir, path);
            mkdirRecurse(full.dirName);
            write(full, content);
        }
        const cutoff = Clock.currTime - keepDays.days;
        foreach (entry; dirEntries(root, SpanMode.shallow))
            foreach (month; dirEntries(entry.name, SpanMode.shallow))
                foreach (day; dirEntries(month.name, SpanMode.shallow))
                    if (timeLastModified(day.name) < cutoff)
                        rmdirRecurse(day.name);
        return null;
    }
    catch (Exception e)
        return "run record " ~ runId ~ " not written: " ~ e.msg;
}
