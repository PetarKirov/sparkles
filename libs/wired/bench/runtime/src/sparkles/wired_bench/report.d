/**
Report rendering: per-dataset tables plus a machine-readable JSON dump.

Follows the `compile-time-bench.d` conventions — `drawHeader` banners,
`drawTable` grids, bold column headers — and dogfoods `sparkles.wired`'s
`toJSON` for the `--json` dump.
*/
module sparkles.wired_bench.report;

import std.algorithm : filter, map;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.process : environment;

import sparkles.base.term_style : Style, stylize;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;
import sparkles.core_cli.ui.table : drawTable;

import sparkles.wired_bench.data : Dataset;
import sparkles.wired_bench.runner : OpResult;

/// Host/toolchain provenance stamped onto every report.
struct EnvInfo
{
    string cpu;       /// CPU model string (empty off Linux)
    string compiler;  /// D compiler name + front-end version
    string isaPreset; /// $WIRED_BENCH_ISA — the nix-built shims' ISA preset
}

/// The full machine-readable report (`--json`).
struct BenchReport
{
    EnvInfo env;
    OpResult[] results;
}

/// Collects the environment provenance of this run.
EnvInfo collectEnvInfo() @safe
{
    import std.compiler : name, version_major, version_minor;

    EnvInfo env;
    env.compiler = format!"%s (front-end %s.%03d)"(name, version_major, version_minor);
    env.isaPreset = environment.get("WIRED_BENCH_ISA", "");
    version (linux)
        env.cpu = cpuModel();
    return env;
}

/// The first `model name` line of `/proc/cpuinfo`, or empty.
private string cpuModel() @safe
{
    import std.algorithm : findSplitAfter, startsWith;
    import std.file : readText;
    import std.string : lineSplitter, strip;

    try
    {
        foreach (line; readText("/proc/cpuinfo").lineSplitter)
            if (line.startsWith("model name"))
                if (const split = line.findSplitAfter(":"))
                    return split[1].strip.idup;
    }
    catch (Exception)
    {
    }
    return "";
}

/// Renders the run header: environment plus the loaded datasets.
void reportEnvironment(in EnvInfo env, const Dataset[] datasets)
{
    import std.stdio : write, writeln;

    "wired runtime JSON bench"
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 72))
        .writeln;

    string[][] rows = [["compiler", env.compiler]];
    if (env.cpu.length)
        rows ~= ["cpu", env.cpu];
    rows ~= ["shim isa", env.isaPreset.length ? env.isaPreset : "(not set — outside the devshell?)"];
    foreach (ds; datasets)
        rows ~= ["dataset " ~ ds.name, format!"%.1f KiB"(ds.text.length / 1024.0)];
    drawTable(rows).write;
}

/// Renders one table per dataset: engine × op rows with throughput and the
/// ratio against the `std.json` row of the same (dataset, op).
void reportResults(const OpResult[] results, const Dataset[] datasets)
{
    import std.stdio : write, writeln;

    foreach (ds; datasets)
    {
        auto rows = results.filter!(r => r.dataset == ds.name).array;
        if (!rows.length)
            continue;

        writeln;
        ds.name.drawHeader(HeaderProps(style: HeaderStyle.banner, width: 72)).writeln;

        string[][] table = [[
            "engine".stylize(Style.bold), "op".stylize(Style.bold),
            "median".stylize(Style.bold), "min".stylize(Style.bold),
            "MB/s".stylize(Style.bold), "×std.json".stylize(Style.bold),
            "iters".stylize(Style.bold), "notes".stylize(Style.bold),
        ]];
        foreach (r; rows)
        {
            if (r.error.length)
            {
                table ~= [r.engine, r.op, "-", "-", "-", "-", "-",
                    "FAILED: " ~ r.error];
                continue;
            }
            const baseline = baselineFor(results, ds.name, r.op);
            table ~= [
                r.engine, r.op,
                formatNs(r.medianNs), formatNs(r.minNs),
                format!"%.0f"(r.mbPerSec),
                baseline > 0 ? format!"%.2f"(r.mbPerSec / baseline) : "-",
                r.iters.to!string,
                r.notes,
            ];
        }
        drawTable(table).write;
    }
}

/// The `std.json` MB/s for `(dataset, op)`, or 0 when absent.
private double baselineFor(const OpResult[] results, string dataset, string op)
    @safe pure nothrow @nogc
{
    foreach (const ref r; results)
        if (r.engine == "std.json" && r.dataset == dataset && r.op == op
            && r.error.length == 0)
            return r.mbPerSec;
    return 0;
}

/// `1234567` ns → `"1.23 ms"`; sub-millisecond times keep µs resolution.
string formatNs(long ns) @safe pure
{
    if (ns >= 1_000_000)
        return format!"%.2f ms"(ns / 1e6);
    return format!"%.1f µs"(ns / 1e3);
}

/// Writes the `--json` dump, dogfooding `sparkles.wired`.
void dumpJson(in BenchReport report, string path)
{
    import std.exception : enforce;
    import sparkles.wired.json : writeJSONFile;

    auto result = writeJSONFile(report, path);
    enforce(!result.hasError, result.hasError ? result.error.msg : "");
}

@("report.formatNs.units")
@safe pure unittest
{
    assert(formatNs(1_234_567) == "1.23 ms");
    assert(formatNs(4_500) == "4.5 µs");
}

@("report.baselineFor.lookup")
@safe pure unittest
{
    const results = [
        OpResult("twitter", "std.json", "parse", 100, 1, 1, 1, 1, 250.0),
        OpResult("twitter", "fast", "parse", 100, 1, 1, 1, 1, 1000.0),
    ];
    assert(baselineFor(results, "twitter", "parse") == 250.0);
    assert(baselineFor(results, "twitter", "serialize") == 0);
}
