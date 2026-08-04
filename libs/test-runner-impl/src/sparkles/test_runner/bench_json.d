/**
 * Machine-readable `--bench-json` reports: every measured row plus a
 * provenance block as one deterministic JSON document, so benchmark baselines
 * can be committed, diffed, and regenerated (see the wired bench's `results/`
 * snapshots).
 *
 * The emission is an explicit writer, not `std.json`: baselines must be
 * byte-stable (fixed field order, sorted label keys) and floats must not
 * render in D's 17-significant-digit default form (which the repo's
 * `pretty-format-json` pre-commit hook rejects) — `jsonNumber` renders
 * integral values as integers and everything else to 6 significant digits,
 * far above benchmark noise. `nan`/infinities (unavailable counters) become
 * `null`, mirroring the table's em dash.
 */
module sparkles.test_runner.bench_json;

import sparkles.test_runner.bench : BenchConfig, BenchStats;
import sparkles.test_runner.metrics : catalog, rowCells;
import sparkles.test_runner.workload : WorkloadWindow;

/// Provenance and the effective measurement knobs stamped onto a report, so a
/// committed baseline is self-describing (the budget it was measured under is
/// part of the data, not tribal knowledge).
struct BenchMeta
{
    string date;          /// ISO day, e.g. "2026-07-10"
    string hostname;      /// "" when unavailable
    string os;
    string arch;
    string compiler;      /// e.g. "LDC (front-end 2.111)"
    string cpu;           /// /proc/cpuinfo model name; "" off Linux
    long minSampleTimeMs; /// effective per-sample/total budget (--bench-min-time)
    uint sampleCount;     /// effective BenchConfig.sampleCount
    const(string)[] provenance; /// suite-registered lines (`benchProvenance`)
}

/// Collects host/toolchain provenance and the run's effective knobs.
BenchMeta collectBenchMeta(in BenchConfig config) @safe
{
    import std.compiler : name, version_major, version_minor;
    import std.datetime.date : Date;
    import std.datetime.systime : Clock;
    import std.format : format;

    BenchMeta m;
    m.date = (cast(Date) Clock.currTime).toISOExtString();
    m.hostname = hostName();
    version (linux)
        m.os = "linux";
    else version (OSX)
        m.os = "macos";
    else version (Windows)
        m.os = "windows";
    else version (Posix)
        m.os = "posix";
    else
        m.os = "unknown";
    version (X86_64)
        m.arch = "x86_64";
    else version (AArch64)
        m.arch = "aarch64";
    else version (X86)
        m.arch = "x86";
    else
        m.arch = "unknown";
    m.compiler = format!"%s (front-end %s.%03d)"(name, version_major, version_minor);
    m.cpu = cpuModel();
    m.minSampleTimeMs = config.minSampleTime.total!"msecs";
    m.sampleCount = config.sampleCount;
    return m;
}

private string hostName() @safe
{
    version (Posix)
    {
        import core.sys.posix.unistd : gethostname;

        char[256] buf = 0;
        const ok = (() @trusted => gethostname(buf.ptr, buf.length))() == 0;
        if (!ok)
            return "";
        foreach (i, ch; buf)
            if (ch == '\0')
                return buf[0 .. i].idup;
        return buf[].idup;
    }
    else version (Windows)
    {
        import std.process : environment;

        return environment.get("COMPUTERNAME", "");
    }
    else
        return "";
}

private string cpuModel() @safe
{
    version (linux)
    {
        import std.algorithm.searching : startsWith;
        import std.file : readText;
        import std.string : indexOf, lineSplitter, strip;

        try
        {
            foreach (line; readText("/proc/cpuinfo").lineSplitter)
                if (line.startsWith("model name"))
                {
                    const colon = line.indexOf(':');
                    if (colon >= 0)
                        return line[colon + 1 .. $].strip;
                }
        }
        catch (Exception)
        {
        }
        return "";
    }
    else
        return "";
}

/// One JSON number: `nan`/infinities → `null` (an unavailable counter, the
/// table's em dash); integral doubles below 2^53 render as integers; the rest
/// to 6 significant digits (never D's 17-digit default).
package(sparkles.test_runner)
string jsonNumber(double v) @safe
{
    import std.format : format;
    import std.math.rounding : floor;
    import std.math.traits : isFinite;

    if (!v.isFinite)
        return "null";
    if (v == floor(v) && v >= -9_007_199_254_740_992.0 && v <= 9_007_199_254_740_992.0)
        return format!"%.0f"(v);
    return format!"%.6g"(v);
}

@("benchJson.number.formatting")
@safe
unittest
{
    assert(jsonNumber(double.nan) == "null");
    assert(jsonNumber(double.infinity) == "null");
    assert(jsonNumber(3_823_300.0) == "3823300", "integral doubles print as integers");
    assert(jsonNumber(0.1) == "0.1");
    assert(jsonNumber(1.651754321e8) == "1.65175e+08", "6 significant digits");
}

/// The row's counting-pass iteration count: every counter tier shares one
/// per-pass count, so the first present source carries it. `0` = no counting
/// pass ran.
private ulong countIterations(in BenchStats row) @safe pure nothrow @nogc
{
    if (!row.perf.isNull)
        return row.perf.get.iters;
    if (!row.tier0.isNull)
        return row.tier0.get.iters;
    if (!row.syscalls.isNull)
        return row.syscalls.get.iters;
    if (!row.raw.isNull)
        return row.raw.get.iters;
    return 0;
}

/// RFC 8259 string escaping: `"`, `\`, and control characters.
package(sparkles.test_runner)
string jsonEscape(scope const(char)[] s) @safe pure
{
    import std.array : appender;
    import std.format : format;

    auto app = appender!string;
    foreach (ch; s)
        switch (ch)
        {
            case '"': app ~= `\"`; break;
            case '\\': app ~= `\\`; break;
            case '\n': app ~= `\n`; break;
            case '\r': app ~= `\r`; break;
            case '\t': app ~= `\t`; break;
            default:
                if (ch < 0x20)
                    app ~= format!"\\u%04x"(ch);
                else
                    app ~= ch;
        }
    return app[];
}

/// The full report document: `{schema, meta, columns, rows}`, pretty-printed
/// with 2-space indent. `rows` keep measurement order (grouping/sorting are
/// presentation concerns; the group dimensions travel in each row's `labels`,
/// whose keys are emitted sorted). `columns` describe the available catalog
/// metrics for these rows, so `metrics` keys match `--list-metrics` names.
/// Schema 2 adds the optional per-row `estimatedMetrics` array naming the
/// `metrics` keys whose values are multiplex-scaled estimates (absent =
/// every metric exact), and — when `@workload` tests ran — a `windows`
/// sibling array of window objects: wall decomposition fields (`null` =
/// unattributable on this host, exactly the table's em dash) and one nested
/// per-source totals object per attached source. Window values are window
/// TOTALS with their own field names, deliberately never the per-iteration
/// `metrics` catalog keys — reusing those names would quietly overload
/// their semantics. A run without workloads emits no `windows` key and is
/// byte-identical to the pre-window document.
string benchReportJson(in BenchStats[] rows, in BenchMeta meta,
    in WorkloadWindow[] windows = null) @safe
{
    import std.algorithm.sorting : sort;
    import std.array : appender;
    import std.conv : to;

    auto o = appender!string;
    o ~= "{\n";
    o ~= "  \"schema\": 2,\n";
    o ~= "  \"meta\": {\n";
    o ~= "    \"date\": \"" ~ jsonEscape(meta.date) ~ "\",\n";
    o ~= "    \"hostname\": \"" ~ jsonEscape(meta.hostname) ~ "\",\n";
    o ~= "    \"os\": \"" ~ jsonEscape(meta.os) ~ "\",\n";
    o ~= "    \"arch\": \"" ~ jsonEscape(meta.arch) ~ "\",\n";
    o ~= "    \"compiler\": \"" ~ jsonEscape(meta.compiler) ~ "\",\n";
    o ~= "    \"cpu\": \"" ~ jsonEscape(meta.cpu) ~ "\",\n";
    o ~= "    \"minSampleTimeMs\": " ~ meta.minSampleTimeMs.to!string ~ ",\n";
    o ~= "    \"sampleCount\": " ~ meta.sampleCount.to!string;
    // Suite-registered provenance (benchProvenance) — only when present, so
    // a suite that registers nothing keeps the pre-provenance meta shape.
    if (meta.provenance.length)
    {
        o ~= ",\n    \"provenance\": [";
        foreach (i, line; meta.provenance)
        {
            o ~= i ? ", " : " ";
            o ~= "\"" ~ jsonEscape(line) ~ "\"";
        }
        o ~= " ]";
    }
    o ~= "\n  },\n";

    o ~= "  \"columns\": [";
    bool firstCol = true;
    foreach (ref d; catalog(rows))
    {
        if (!d.available)
            continue;
        o ~= firstCol ? "\n" : ",\n";
        firstCol = false;
        o ~= "    { \"name\": \"" ~ jsonEscape(d.name)
            ~ "\", \"header\": \"" ~ jsonEscape(d.header)
            ~ "\", \"format\": \"" ~ d.format.to!string
            ~ "\", \"class\": \"" ~ d.cls.to!string
            ~ "\", \"source\": \"" ~ jsonEscape(d.source) ~ "\" }";
    }
    o ~= firstCol ? "],\n" : "\n  ],\n";

    o ~= "  \"rows\": [";
    foreach (ri, ref row; rows)
    {
        o ~= ri ? ",\n" : "\n";
        const isError = row.error.length > 0;
        o ~= "    {\n";
        o ~= "      \"name\": \"" ~ jsonEscape(row.name) ~ "\",\n";

        o ~= "      \"labels\": {";
        auto keys = row.labels.keys;
        keys.sort; // AA order is unspecified; baselines must be byte-stable
        foreach (ki, k; keys)
        {
            o ~= ki ? ", " : " ";
            o ~= "\"" ~ jsonEscape(k) ~ "\": \"" ~ jsonEscape(row.labels[k]) ~ "\"";
        }
        o ~= keys.length ? " },\n" : "},\n";

        if (isError)
        {
            o ~= "      \"iterations\": null,\n";
            o ~= "      \"samples\": null,\n";
            o ~= "      \"medianNs\": null,\n";
            o ~= "      \"deviationNs\": null,\n";
            o ~= "      \"minNs\": null,\n";
            o ~= "      \"maxNs\": null,\n";
            o ~= "      \"metrics\": {},\n";
        }
        else
        {
            o ~= "      \"iterations\": " ~ row.iterations.to!string ~ ",\n";
            o ~= "      \"samples\": " ~ row.samples.to!string ~ ",\n";
            o ~= "      \"medianNs\": " ~ jsonNumber(row.nsPerIterMedian) ~ ",\n";
            o ~= "      \"deviationNs\": " ~ jsonNumber(row.nsPerIterDeviation) ~ ",\n";
            o ~= "      \"minNs\": " ~ jsonNumber(row.nsPerIterMin) ~ ",\n";
            o ~= "      \"maxNs\": " ~ jsonNumber(row.nsPerIterMax) ~ ",\n";
            o ~= "      \"metrics\": {";
            bool firstCell = true;
            string estimated;
            foreach (ref c; rowCells(row))
            {
                o ~= firstCell ? " " : ", ";
                firstCell = false;
                o ~= "\"" ~ jsonEscape(c.name) ~ "\": " ~ jsonNumber(c.value);
                if (c.estimated)
                    estimated ~= (estimated.length ? ", \"" : "\"")
                        ~ jsonEscape(c.name) ~ "\"";
            }
            o ~= firstCell ? "},\n" : " },\n";
            // Multiplex-scaled estimates are labeled machine-readably too, so
            // a baseline comparison never mistakes an estimate for an exact
            // count (schema 2; absent = every metric exact).
            if (estimated.length)
                o ~= "      \"estimatedMetrics\": [ " ~ estimated ~ " ],\n";
            // The effective counting-pass iteration count (shared by every
            // counter tier), so per-pass totals are auditable — a validator
            // can multiply per-iteration cells back to what the pass counted.
            // Absent when no counting pass ran (schema 2).
            if (const ci = countIterations(row))
                o ~= "      \"countIterations\": " ~ ci.to!string ~ ",\n";
        }
        o ~= "      \"error\": \"" ~ jsonEscape(row.error) ~ "\"\n";
        o ~= "    }";
    }
    o ~= rows.length ? "\n  ]" : "]";
    if (windows.length)
    {
        o ~= ",\n  \"windows\": [";
        foreach (wi, ref w; windows)
        {
            o ~= wi ? ",\n" : "\n";
            o ~= windowJson(w);
        }
        o ~= "\n  ]";
    }
    o ~= "\n}\n";
    return o[];
}

/// One `windows` element. Field order is fixed for byte-stable baselines;
/// absent sources omit their keys (the `Nullable` contract), `nan`
/// components emit `null`, and `skipped` appears only when `true`.
private string windowJson(in WorkloadWindow w) @safe
{
    import std.array : appender;
    import std.conv : to;

    auto o = appender!string;
    o ~= "    {\n";
    o ~= "      \"name\": \"" ~ jsonEscape(w.name) ~ "\",\n";
    o ~= "      \"reps\": " ~ w.reps.to!string ~ ",\n";
    if (w.error.length)
    {
        // Mirror the error-row shape: every always-present key stays
        // present as null, so consumers can read windows position-blind.
        o ~= "      \"wallNs\": null,\n";
        o ~= "      \"scope\": null,\n";
        o ~= "      \"onCpuUserNs\": null,\n";
        o ~= "      \"onCpuKernelNs\": null,\n";
        o ~= "      \"offCpuRunqueueNs\": null,\n";
        o ~= "      \"offCpuDiskNs\": null,\n";
        o ~= "      \"offCpuOtherNs\": null,\n";
        if (w.skipped)
            o ~= "      \"skipped\": true,\n";
        o ~= "      \"error\": \"" ~ jsonEscape(w.error) ~ "\"\n";
        o ~= "    }";
        return o[];
    }

    o ~= "      \"wallNs\": " ~ w.wall.wallNs.to!string ~ ",\n";
    o ~= "      \"scope\": \"" ~ jsonEscape(w.wall.scope_) ~ "\",\n";
    o ~= "      \"onCpuUserNs\": " ~ jsonNumber(w.wall.onCpuUserNs) ~ ",\n";
    o ~= "      \"onCpuKernelNs\": " ~ jsonNumber(w.wall.onCpuKernelNs) ~ ",\n";
    o ~= "      \"offCpuRunqueueNs\": " ~ jsonNumber(w.wall.offCpuRunqueueNs) ~ ",\n";
    o ~= "      \"offCpuDiskNs\": " ~ jsonNumber(w.wall.offCpuDiskNs) ~ ",\n";
    o ~= "      \"offCpuOtherNs\": " ~ jsonNumber(w.wall.offCpuOtherNs) ~ ",\n";

    if (!w.perf.isNull)
    {
        const p = w.perf.get;
        o ~= "      \"perf\": { \"instructions\": " ~ jsonNumber(p.instructions)
            ~ ", \"cycles\": " ~ jsonNumber(p.cycles)
            ~ ", \"branches\": " ~ jsonNumber(p.branches)
            ~ ", \"branchMisses\": " ~ jsonNumber(p.branchMisses)
            ~ ", \"cacheReferences\": " ~ jsonNumber(p.cacheReferences)
            ~ ", \"cacheMisses\": " ~ jsonNumber(p.cacheMisses)
            ~ ", \"pageFaults\": " ~ jsonNumber(p.pageFaults)
            ~ ", \"scale\": " ~ jsonNumber(p.scale)
            ~ ", \"userOnly\": " ~ (p.userOnly ? "true" : "false") ~ " },\n";
    }
    if (!w.tier0.isNull)
    {
        const t = w.tier0.get;
        o ~= "      \"tier0\": { \"minflt\": " ~ jsonNumber(t.minflt)
            ~ ", \"majflt\": " ~ jsonNumber(t.majflt)
            ~ ", \"volCs\": " ~ jsonNumber(t.volCs)
            ~ ", \"involCs\": " ~ jsonNumber(t.involCs)
            ~ ", \"syscr\": " ~ jsonNumber(t.syscr)
            ~ ", \"syscw\": " ~ jsonNumber(t.syscw)
            ~ ", \"rchar\": " ~ jsonNumber(t.rdChars)
            ~ ", \"wchar\": " ~ jsonNumber(t.wrChars)
            ~ ", \"readBytes\": " ~ jsonNumber(t.rdBytes)
            ~ ", \"writeBytes\": " ~ jsonNumber(t.wrBytes) ~ " },\n";
    }
    if (!w.syscalls.isNull)
    {
        const s = w.syscalls.get;
        o ~= "      \"syscalls\": { \"total\": " ~ jsonNumber(s.total)
            ~ ", \"named\": {";
        foreach (i, name; s.named)
        {
            o ~= i ? ", " : " ";
            o ~= "\"" ~ jsonEscape(name) ~ "\": "
                ~ jsonNumber(i < s.counts.length ? s.counts[i] : double.nan);
        }
        o ~= s.named.length ? " }" : "}";
        o ~= ", \"scale\": " ~ jsonNumber(s.scale) ~ " },\n";
    }
    if (!w.raw.isNull)
    {
        const r = w.raw.get;
        o ~= "      \"raw\": { \"events\": {";
        foreach (i, sel; r.selectors)
        {
            o ~= i ? ", " : " ";
            o ~= "\"" ~ jsonEscape(sel) ~ "\": "
                ~ jsonNumber(i < r.values.length ? r.values[i] : double.nan);
        }
        o ~= r.selectors.length ? " }" : "}";
        o ~= ", \"scale\": " ~ jsonNumber(r.scale) ~ " },\n";
    }

    if (!w.psi.isNull)
    {
        // System-wide stall integrals — diagnostics, self-described by the
        // scope field (M8's cgroup-scoped source will emit "cgroup").
        const p = w.psi.get;
        o ~= "      \"psi\": { \"scope\": \"system\""
            ~ ", \"ioSomeNs\": " ~ jsonNumber(p.ioSomeNs)
            ~ ", \"ioFullNs\": " ~ jsonNumber(p.ioFullNs)
            ~ ", \"memSomeNs\": " ~ jsonNumber(p.memSomeNs)
            ~ ", \"memFullNs\": " ~ jsonNumber(p.memFullNs)
            ~ ", \"cpuSomeNs\": " ~ jsonNumber(p.cpuSomeNs) ~ " },\n";
    }

    if (!w.regime.isNull)
    {
        import std.conv : to;

        // The page-cache regime workloadFiles established for this window
        // (requested vs verified-effective; fractions nan→null); the note
        // stays separate from the wall note here even though the table
        // composes them into one cell.
        const g = w.regime.get;
        o ~= "      \"regime\": { \"requested\": \"" ~ g.requested.to!string
            ~ "\", \"effective\": \"" ~ g.effective.to!string
            ~ "\", \"residentBefore\": " ~ jsonNumber(g.residentBefore)
            ~ ", \"residentAfter\": " ~ jsonNumber(g.residentAfter);
        if (g.note.length)
            o ~= ", \"note\": \"" ~ jsonEscape(g.note) ~ "\"";
        o ~= " },\n";
    }

    if (w.wall.note.length)
        o ~= "      \"note\": \"" ~ jsonEscape(w.wall.note) ~ "\",\n";
    o ~= "      \"error\": \"\"\n";
    o ~= "    }";
    return o[];
}

@("benchJson.document.roundTrips")
@system
unittest
{
    import std.json : JSONType, parseJSON;
    import std.typecons : Nullable;
    import sparkles.test_runner.bench : Metric, Unit;
    import sparkles.test_runner.perf : PerfStats;

    BenchStats measured;
    measured.name = "mir-ion";
    measured.labels = ["operation": "parse", "dataset": "twitter"];
    measured.iterations = 1;
    measured.samples = 42;
    measured.nsPerIterMedian = 3_823_300;
    measured.nsPerIterDeviation = 41_200;
    measured.nsPerIterMin = 3_615_100;
    measured.nsPerIterMax = 4_891_000;
    measured.metrics = [Metric(Unit("B"), 1000.0, Metric.Mode.rate)];
    PerfStats p;
    p.cycles = 100;
    p.instructions = 200;
    measured.perf = p;

    BenchStats plain;
    plain.name = "sum/64";
    plain.iterations = 1;
    plain.samples = 32;
    plain.nsPerIterMedian = 110;

    const meta = BenchMeta(date: "2026-07-10", hostname: "h", os: "linux",
        arch: "x86_64", compiler: "LDC (front-end 2.111)", cpu: "cpu",
        minSampleTimeMs: 5, sampleCount: 32);
    const doc = parseJSON(benchReportJson([measured, plain], meta));

    assert(doc["schema"].integer == 2);
    assert(doc["meta"]["minSampleTimeMs"].integer == 5);
    assert(doc["rows"].array.length == 2);
    assert(doc["rows"][0]["labels"]["dataset"].str == "twitter");
    assert(doc["rows"][0]["metrics"]["ipc"].get!double == 2.0);
    assert("estimatedMetrics" !in doc["rows"][0],
        "exact counts carry no estimate list");
    assert(doc["rows"][0]["medianNs"].integer == 3_823_300);
    assert(doc["rows"][1]["metrics"].object.length == 0 || "ipc" !in doc["rows"][1]["metrics"]);

    bool sawIpc;
    foreach (col; doc["columns"].array)
        if (col["name"].str == "ipc")
        {
            sawIpc = true;
            assert(col["source"].str == "perf");
        }
    assert(sawIpc);
}

@("benchJson.errorRow.nullTiming")
@system
unittest
{
    import std.json : JSONType, parseJSON;

    BenchStats bad;
    bad.name = "crashed";
    bad.labels = ["dataset": "canada"];
    bad.error = "object.Exception: boom";

    const doc = parseJSON(benchReportJson([bad], BenchMeta(date: "2026-07-10")));
    const row = doc["rows"][0];
    assert(row["error"].str == "object.Exception: boom");
    assert(row["medianNs"].type == JSONType.null_);
    assert(row["iterations"].type == JSONType.null_);
    assert(row["metrics"].object.length == 0);
    assert(row["labels"]["dataset"].str == "canada");
}

@("benchJson.deterministic.sortedLabels")
@system
unittest
{
    BenchStats a, b;
    a.name = b.name = "x";
    a.iterations = b.iterations = 1;
    // Different insertion orders must emit identical documents.
    a.labels = ["k1": "v1", "k2": "v2"];
    b.labels = ["k2": "v2"];
    b.labels["k1"] = "v1";
    const meta = BenchMeta(date: "2026-07-10");
    const one = benchReportJson([a], meta);
    assert(one == benchReportJson([b], meta));
    assert(one == benchReportJson([a], meta), "re-emission is byte-identical");
}

@("benchJson.escaping")
@system
unittest
{
    import std.json : parseJSON;

    BenchStats row;
    row.name = "quote \" back \\ newline \n tab \t";
    row.iterations = 1;
    const doc = parseJSON(benchReportJson([row], BenchMeta(date: "2026-07-10")));
    assert(doc["rows"][0]["name"].str == row.name, "escaping round-trips");
}

@("benchJson.meta.collect")
@system
unittest
{
    import core.time : msecs;
    import std.algorithm.searching : canFind;

    const meta = collectBenchMeta(BenchConfig(minSampleTime: 2000.msecs));
    assert(meta.minSampleTimeMs == 2000);
    assert(meta.sampleCount == 32);
    assert(meta.compiler.canFind("front-end"));
    assert(meta.os.length && meta.arch.length);
    assert(meta.date.length == 10); // ISO day
}

@("benchJson.rows.estimatedMetrics")
@system
unittest
{
    import std.json : parseJSON;
    import sparkles.test_runner.perf : PerfStats;

    BenchStats row;
    row.name = "scaled";
    row.iterations = 1;
    row.samples = 32;
    row.nsPerIterMedian = 100;
    PerfStats p;
    p.cycles = 100;
    p.instructions = 200;
    p.scale = 0.5; // a half-scheduled pass: values are estimates
    row.perf = p;

    const doc = parseJSON(benchReportJson([row], BenchMeta(date: "2026-07-10")));
    const est = doc["rows"][0]["estimatedMetrics"].array;
    assert(est.length > 0);
    bool foundIpc;
    foreach (e; est)
        foundIpc |= e.str == "ipc";
    assert(foundIpc, "the scaled perf cells are named");
}

@("benchJson.meta.provenance")
@system
unittest
{
    import std.json : parseJSON;

    BenchStats row;
    row.name = "x";
    row.iterations = 1;
    const meta = BenchMeta(date: "2026-07-12",
        provenance: ["glibc malloc trim/mmap thresholds raised to 64 MiB",
            "codegen: library-inline"]);
    const doc = parseJSON(benchReportJson([row], meta));
    const p = doc["meta"]["provenance"].array;
    assert(p.length == 2);
    assert(p[0].str == "glibc malloc trim/mmap thresholds raised to 64 MiB");
    assert(p[1].str == "codegen: library-inline");

    const bare = parseJSON(benchReportJson([row], BenchMeta(date: "2026-07-12")));
    assert("provenance" !in bare["meta"], "no lines registered — no key");
}

@("benchJson.rows.countIterations")
@system
unittest
{
    import std.json : parseJSON;
    import sparkles.test_runner.perf : PerfStats;

    BenchStats counted;
    counted.name = "counted";
    counted.iterations = 1;
    PerfStats p;
    p.iters = 7;
    p.cycles = 100;
    counted.perf = p;

    BenchStats uncounted;
    uncounted.name = "plain";
    uncounted.iterations = 1;

    const doc = parseJSON(benchReportJson([counted, uncounted],
        BenchMeta(date: "2026-07-12")));
    assert(doc["rows"][0]["countIterations"].integer == 7);
    assert("countIterations" !in doc["rows"][1], "no counting pass — no key");
}

@("benchJson.windows.roundTrip")
@system
unittest
{
    import std.json : JSONType, parseJSON;
    import std.typecons : nullable;
    import sparkles.test_runner.perf : PerfStats;
    import sparkles.test_runner.syscalls : SyscallStats;

    WorkloadWindow w;
    w.name = "ingest";
    w.reps = 2;
    w.wall.wallNs = 41_235_678;
    w.wall.scope_ = "thread";
    w.wall.onCpuUserNs = 31_000_000;
    w.wall.onCpuKernelNs = 4_000_000;
    // runqueue stays nan (schedstat-less host) → null in the document
    w.wall.offCpuOtherNs = 6_235_678;
    w.wall.note = "runqueue wait unattributed (schedstat unreadable) — included in other";
    PerfStats p;
    p.iters = 1;
    p.instructions = 2.41e9;
    p.cycles = 3.1e9;
    p.pageFaults = 12;
    w.perf = nullable(p);
    SyscallStats s;
    s.iters = 1;
    s.total = 1234;
    s.named = ["read"];
    s.counts = [600.0];
    w.syscalls = nullable(s);

    WorkloadWindow err;
    err.name = "bad";
    err.reps = 1;
    err.error = "object.Exception: boom";

    WorkloadWindow skipped;
    skipped.name = "skippy";
    skipped.reps = 1;
    skipped.error = "no hardware";
    skipped.skipped = true;

    const doc = parseJSON(benchReportJson(null, BenchMeta(date: "2026-08-02"),
        [w, err, skipped]));
    assert(doc["schema"].integer == 2, "windows fold into unreleased schema 2");
    const win = doc["windows"][0];
    assert(win["name"].str == "ingest");
    assert(win["reps"].integer == 2);
    assert(win["wallNs"].integer == 41_235_678);
    assert(win["scope"].str == "thread");
    assert(win["onCpuUserNs"].integer == 31_000_000);
    assert(win["offCpuRunqueueNs"].type == JSONType.null_,
        "unattributable = null, exactly the table's em dash");
    assert(win["offCpuDiskNs"].type == JSONType.null_,
        "PSI is system-scoped; disk attribution lands with M8 cgroups");
    assert(win["perf"]["instructions"].integer == 2_410_000_000,
        "integral totals render as JSON integers");
    assert(win["perf"]["scale"].integer == 1);
    assert(win["syscalls"]["total"].integer == 1234);
    assert(win["syscalls"]["named"]["read"].integer == 600);
    assert("tier0" !in win, "an absent source omits its key");
    assert("raw" !in win);
    assert("psi" !in win, "psi omits its key like every absent source");
    assert(win["note"].str.length > 0);
    assert(win["error"].str == "");

    const bad = doc["windows"][1];
    assert(bad["wallNs"].type == JSONType.null_);
    // The always-present keys mirror the error-row shape: null, not absent.
    assert(bad["scope"].type == JSONType.null_);
    assert(bad["onCpuUserNs"].type == JSONType.null_);
    assert(bad["offCpuOtherNs"].type == JSONType.null_);
    assert(bad["error"].str == "object.Exception: boom");
    assert("skipped" !in bad);
    assert(doc["windows"][2]["skipped"].boolean);
}

@("benchJson.windows.absentKeepsDocumentByteIdentical")
@safe
unittest
{
    // A run without workloads must stay byte-identical to the pre-window
    // document — `windows` is a pure addition, not a schema perturbation.
    BenchStats row;
    row.name = "r";
    row.iterations = 1;
    const meta = BenchMeta(date: "2026-08-02");
    assert(benchReportJson([row], meta) == benchReportJson([row], meta, null));
    assert(benchReportJson(null, meta) == benchReportJson(null, meta, null));

    // And a psi-less window (a CONFIG_PSI=n host) must omit the psi key —
    // asserted explicitly, not incidentally.
    WorkloadWindow noPsi;
    noPsi.name = "w";
    noPsi.reps = 1;
    noPsi.wall.wallNs = 1;
    noPsi.wall.scope_ = "thread";
    import std.algorithm.searching : canFind;

    assert(!benchReportJson(null, meta, [noPsi]).canFind("\"psi\""));
}

@("benchJson.windows.psiObject")
@system
unittest
{
    import std.json : JSONType, parseJSON;
    import std.typecons : nullable;
    import sparkles.test_runner.workload : PsiStats;

    WorkloadWindow w;
    w.name = "with-psi";
    w.reps = 1;
    w.wall.wallNs = 10_000_000;
    w.wall.scope_ = "thread";
    PsiStats p;
    p.ioSomeNs = 3_000_000;
    p.ioFullNs = 200_000;
    p.memSomeNs = 0;
    // memFullNs stays nan (absent full line) → null
    p.cpuSomeNs = 14_000;
    w.psi = nullable(p);

    const doc = parseJSON(benchReportJson(null, BenchMeta(date: "2026-08-03"), [w]));
    const psi = doc["windows"][0]["psi"];
    assert(psi["scope"].str == "system",
        "the object self-describes its scope — M8's cgroup source will differ");
    assert(psi["ioSomeNs"].integer == 3_000_000);
    assert(psi["ioFullNs"].integer == 200_000);
    assert(psi["memSomeNs"].integer == 0, "a zero system delta is a true statement");
    assert(psi["memFullNs"].type == JSONType.null_, "absent full line → null");
    assert(psi["cpuSomeNs"].integer == 14_000);
    assert("cpuFullNs" !in psi, "pinned-zero system cpu-full is not emitted");
    // The decomposition slot stays honest: no attribution from system scope.
    assert(doc["windows"][0]["offCpuDiskNs"].type == JSONType.null_);
}

@("benchJson.windows.regimeObject")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.json : JSONType, parseJSON;
    import std.typecons : nullable;
    import sparkles.test_runner.attributes : CacheRegime;
    import sparkles.test_runner.cache_regime : CacheRegimeStamp;

    WorkloadWindow w;
    w.name = "cold-run";
    w.reps = 1;
    w.wall.wallNs = 5_000_000;
    w.wall.scope_ = "thread";
    w.regime = nullable(CacheRegimeStamp(
        requested: CacheRegime.cold, effective: CacheRegime.steadyState,
        residentBefore: 1.0, residentAfter: double.nan,
        note: "cold impossible on tmpfs (the pages ARE the file) — ran steady-state"));

    const doc = parseJSON(benchReportJson(null, BenchMeta(date: "2026-08-05"), [w]));
    const g = doc["windows"][0]["regime"];
    assert(g["requested"].str == "cold");
    assert(g["effective"].str == "steadyState");
    assert(g["residentBefore"].integer == 1);
    assert(g["residentAfter"].type == JSONType.null_, "nan fraction → null");
    assert(g["note"].str.canFind("tmpfs"));

    // Stampless windows omit the key — and the whole document stays free
    // of it (the byte-identity contract for regime-less runs).
    WorkloadWindow plain;
    plain.name = "plain";
    plain.reps = 1;
    plain.wall.wallNs = 1;
    plain.wall.scope_ = "thread";
    assert(!benchReportJson(null, BenchMeta(date: "2026-08-05"), [plain])
        .canFind("\"regime\""));
}
