#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_compile_time_bench"

    dependency "sparkles:wired"    path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base"     path="../../.."

    dflags "-preview=in" "-preview=dip1000"
+/
/**
Compile-time benchmark for `sparkles:wired`.

Generates synthetic consumer modules of parameterized shape and size, compiles
each frontend-only (`-o-`) with LDC's `-ftime-trace`, and reports where the
compiler spent its time — wall clock, peak resident-set size and CPU time of
the compiler tree (via `sparkles:core-cli`'s resource-monitored executor),
template-instantiation and CTFE totals (interval-union per category, so nested
events are not double-counted), event counts, and the top `sparkles.wired`
templates by time. A separate
`-vtemplates` pass counts instantiations of the `sparkles.wired` templates —
a deterministic signal for validating refactorings, independent of timer noise.

Per-instance `Sema1: Template Instance` trace events need LDC ≥ 1.42; under
LDC 1.41 the template-time column reads 0 and the CTFE, wall, and
`-vtemplates` metrics still apply.

Workloads:
$(LIST
    * `wide`  — one struct with N scalar/string fields, a quarter annotated
    * `deep`  — a chain of N nested structs, annotations sprinkled along it
    * `enums` — N/4 enums of 8 members used as plain, array, and AA-key fields
    * `mixed` — N fields cycling through wrappers, sum types, enums, converts
)

Usage:
---
./compile-time-bench.d [--sizes=8,32,128] [--iters=3] \
    [--workloads=wide,deep,enums,mixed] [--json=FILE] [--top=8] [--keep]
---

Wall time is the minimum over `--iters` runs; trace-derived metrics come from
the last run (they are deterministic). Pass `--json` to dump the metrics for
before/after comparison of an optimization.
*/
module compile_time_bench;

import std.algorithm : canFind, filter, map, maxElement, minElement, sort,
    startsWith, sum;
import std.array : array, join, split;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : enforce;
import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, writeFile = write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.logger : LogLevel;
import std.path : buildPath, dirName;
import std.process : execute;
import std.range : iota, retro;
import std.stdio : File, stderr, write, writefln, writeln;

import sparkles.base.logger : info, initLogger;
import sparkles.base.term_style : Style, stylize;

import sparkles.core_cli.args : CliOption, parseCliArgs;
import sparkles.core_cli.help_formatting : HelpInfo;
import sparkles.core_cli.process_utils : enforceExitStatus, executeMonitored;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;
import sparkles.core_cli.ui.table : drawTable;

import sparkles.wired.json : toJSON;

/// Command-line configuration, parsed by `sparkles:core-cli`.
struct BenchOptions
{
    @CliOption("s|sizes", "Comma-separated workload sizes (default 8,32,128)")
    string sizes = "8,32,128";

    @CliOption("w|workloads", "Comma-separated workload names (default all)")
    string workloads = "wide,deep,enums,mixed";

    @CliOption("i|iters", "Compile runs per data point; wall time is the minimum")
    uint iters = 3;

    @CliOption("t|top", "How many top templates to show per data point")
    uint top = 8;

    @CliOption("j|json", "Dump metrics as JSON to this file")
    string json;

    @CliOption("c|compiler", "D compiler to benchmark (must support -ftime-trace)")
    string compiler = "ldc2";

    @CliOption("k|keep", "Keep the generated workload modules")
    bool keep;
}

int main(string[] args)
{
    initLogger(LogLevel.info);

    const opts = args.parseCliArgs!BenchOptions(
        HelpInfo("compile-time-bench", "Compile-time benchmark for sparkles:wired."));

    const sizes = opts.sizes.split(',').map!(to!uint).array;
    const workloads = opts.workloads.split(',');
    const importPaths = wiredImportPaths();
    const genDir = buildPath(tempDir, "wired-compile-bench");
    mkdirRecurse(genDir);
    scope (exit)
        if (!opts.keep)
            rmdirRecurse(genDir);

    Metrics[] results;
    foreach (workload; workloads)
        foreach (size; sizes)
        {
            info(i"benchmarking $(workload) size=$(size)");
            const name = format!"bench_%s_%s"(workload, size);
            const file = buildPath(genDir, name ~ ".d");
            writeFile(file, generate(workload, name, size));

            auto m = measure(opts.compiler, file,
                buildPath(genDir, name ~ ".trace.json"), importPaths, opts.iters);
            m.workload = workload;
            m.size = size;
            report(m, opts.top);
            results ~= m;
        }

    if (opts.json.length)
    {
        // Dogfood sparkles:wired to serialize the benchmark's own results.
        auto encoded = toJSON(results);
        enforce(encoded.hasValue, "wired failed to encode metrics");
        File(opts.json, "w").writeln(encoded.value[]);
        writefln!"\nmetrics written to %s"(opts.json);
    }
    if (opts.keep)
        writefln!"\ngenerated modules kept in %s"(genDir);
    return 0;
}

/// Import paths of `sparkles:wired` and its dependencies, resolved by dub from
/// the package directory this script lives in.
string[] wiredImportPaths()
{
    const wiredRoot = __FILE_FULL_PATH__.dirName.dirName;
    const r = execute(["dub", "describe", "--root", wiredRoot,
        "--data=import-paths", "--data-list"]);
    if (r.status != 0)
        stderr.writeln(r.output);
    enforceExitStatus(r.status, "dub describe");
    return r.output.split('\n').filter!(l => l.length).array;
}

// ─────────────────────────────────────────────────────────────────────────────
// Workload generation
// ─────────────────────────────────────────────────────────────────────────────

/// The source of one synthetic consumer module exercising encode + decode.
string generate(string workload, string moduleName, uint size)
{
    string header = "module " ~ moduleName ~ ";\n\n"
        ~ "import core.time : Duration, msecs;\n"
        ~ "import std.json : JSONValue;\n"
        ~ "import std.sumtype : SumType;\n"
        ~ "import std.typecons : Nullable;\n"
        ~ "import optional : Optional;\n\n"
        ~ "import sparkles.wired.json;\n"
        ~ "import sparkles.wired.policy;\n"
        ~ "import sparkles.base.text.case_style : CaseStyle;\n\n";

    switch (workload)
    {
        case "wide": return header ~ genWide(size);
        case "deep": return header ~ genDeep(size);
        case "enums": return header ~ genEnums(size);
        case "mixed": return header ~ genMixed(size);
        default: throw new Exception("unknown workload: " ~ workload);
    }
}

/// The encode + decode instantiation anchor for the root type — the
/// public surface a consumer instantiates (text-based, SPEC §11.6).
private string anchor(string type)
{
    return "\nauto enc(const " ~ type ~ " v) => toJSON(v);\n"
        ~ "auto dec(const(char)[] t) => fromJSON!" ~ type ~ "(t);\n";
}

/// One struct, `size` scalar/string fields; every 4th field renamed, every 6th
/// optional — the shape of a large flat config aggregate.
string genWide(uint size)
{
    static immutable types = ["int", "string", "double", "bool"];
    const fields = size.iota.map!((i) {
        string f;
        if (i % 4 == 3)
            f ~= format!"    @WireName!Json(\"wire%s\")\n"(i);
        if (i % 6 == 5)
            f ~= "    @WireOptional()\n";
        return f ~ format!"    %s someField%s;\n"(types[i % $], i);
    }).join;
    return "@WireCase!Json(CaseStyle.snakeCase)\nstruct Wide\n{\n"
        ~ fields ~ "}\n" ~ anchor("Wide");
}

/// A chain of `size` nested structs; every 4th level recased, every 3rd field
/// renamed — the shape of a deeply structured document.
string genDeep(uint size)
{
    const levels = size.iota.retro.map!((lvl) {
        string s;
        if (lvl % 4 == 1)
            s ~= "@WireCase!Json(CaseStyle.snakeCase)\n";
        s ~= format!"struct Level%s\n{\n"(lvl);
        if (lvl % 3 == 2)
            s ~= format!"    @WireName!Json(\"depth%s\")\n"(lvl);
        s ~= format!"    int payloadValue%s;\n    string labelText%s;\n"(lvl, lvl);
        if (lvl + 1 < size)
            s ~= format!"    Level%s child;\n"(lvl + 1);
        return s ~ "}\n\n";
    }).join;
    return levels ~ anchor("Level0");
}

/// `size / 4` enums of 8 members each, used as plain fields, array elements,
/// and AA keys — the shape that exercises name resolution and the slot lattice.
string genEnums(uint size)
{
    const nEnums = size < 4 ? 1 : size / 4;

    const enums = nEnums.iota.map!((e) {
        string s;
        if (e % 2 == 0)
            s ~= "@WireCase!Json(CaseStyle.snakeCase)\n";
        if (e % 3 == 2)
            s ~= "@WireRepr!Json(Repr.value)\n";
        s ~= format!"enum Choice%s\n{\n"(e);
        s ~= 8.iota.map!((m) {
            string member;
            if (e == 0 && m % 4 == 3)
                member ~= format!"    @WireName!Json(\"alias%s\")\n"(m);
            return member ~ format!"    optionValue%s,\n"(m);
        }).join;
        return s ~ "}\n\n";
    }).join;

    const fields = nEnums.iota.map!((e) {
        string s = format!"    Choice%s plain%s;\n"(e, e);
        if (e % 2 == 1)
            s ~= "    @WireCase!Json(CaseStyle.kebabCase, WireTarget.value)\n";
        s ~= format!"    Choice%s[] list%s;\n"(e, e);
        if (e % 3 != 2) // value-repr enums as AA keys need no name uniqueness
            s ~= format!"    int[Choice%s] table%s;\n"(e, e);
        return s;
    }).join;

    return enums ~ "struct Enums\n{\n" ~ fields ~ "}\n" ~ anchor("Enums");
}

/// `size` fields cycling through wrappers, sum types, enums, arrays, AA keys,
/// converts, and small nested structs — the shape of a realistic API payload.
string genMixed(uint size)
{
    const header = "enum Kind { alphaMode, betaMode, gammaMode }\n\n"
        ~ "struct Point\n{\n    double xCoord;\n    double yCoord;\n}\n\n"
        ~ "@WireCase!Json(CaseStyle.snakeCase)\nstruct Mixed\n{\n";
    const fields = size.iota.map!((i) {
        string s;
        final switch (i % 9)
        {
            case 0: s = format!"    long counterValue%s;\n"(i); break;
            case 1: s = format!"    @WireOptional() Nullable!int maybeInt%s;\n"(i); break;
            case 2: s = format!"    @WireOptional(WireSkip.whenDefault) Optional!string maybeText%s;\n"(i); break;
            case 3: s = format!"    @(WireMatch.first!Json) SumType!(long, string) either%s;\n"(i); break;
            case 4: s = format!"    @WireConvert!(d => d.total!\"msecs\", ms => msecs(ms)) Duration timeout%s;\n"(i); break;
            case 5: s = format!"    @WireName!Json(\"kind%s\") Kind kindTag%s;\n"(i, i); break;
            case 6: s = format!"    @WireCase!Json(CaseStyle.kebabCase, WireTarget.value) Kind[] kindList%s;\n"(i); break;
            case 7: s = format!"    int[Kind] kindTable%s;\n"(i); break;
            case 8: s = format!"    Point position%s;\n"(i); break;
        }
        return s;
    }).join;
    return header ~ fields ~ "}\n" ~ anchor("Mixed");
}

// ─────────────────────────────────────────────────────────────────────────────
// Measurement
// ─────────────────────────────────────────────────────────────────────────────

struct Metrics
{
    string workload;        /// workload name this data point belongs to
    uint size;              /// workload size this data point belongs to
    long wallMs;            /// best-of-iters wall clock of the whole compile
    long frontendMs;        /// span of all trace events (≈ frontend time)
    long templateMs;        /// interval-union of template-instantiation events
    long ctfeMs;            /// interval-union of CTFE events
    size_t peakRssBytes;    /// peak RSS of the compiler tree (0 off Linux)
    long cpuMs;             /// summed user+system CPU of the tree (0 off Linux)
    size_t templateCount;   /// number of template-instantiation events
    size_t ctfeCount;       /// number of CTFE events
    size_t instTotal;       /// -vtemplates: total wired-template instantiations
    size_t instDistinct;    /// -vtemplates: distinct wired-template instantiations
    TopEntry[] topWired;    /// top sparkles.wired templates by unioned time
    InstEntry[] topInst;    /// top sparkles.wired templates by instantiation count
    TopEntry[] byPackage;   /// template time attributed to each root package
}

struct TopEntry
{
    string name;
    long ms;
    size_t count;
}

struct InstEntry
{
    string name;
    size_t total;
    size_t distinct;
}

/// Compiles `file` `iters` times frontend-only, parsing the time trace of the
/// last run into aggregate metrics.
Metrics measure(string compiler, string file, string traceFile,
    const string[] importPaths, uint iters)
{
    const cmd = [compiler, "-c", "-o-", "-preview=in", "-preview=dip1000"]
        ~ importPaths.map!(p => "-I" ~ p).array
        ~ ["-ftime-trace", "-ftime-trace-file=" ~ traceFile,
            "--ftime-trace-granularity=0", file];

    Metrics m;
    m.wallMs = long.max;
    foreach (i; 0 .. iters)
    {
        auto sw = StopWatch(AutoStart.yes);
        const r = executeMonitored(cmd);
        const elapsed = sw.peek.total!"msecs";
        if (r.status != 0)
            stderr.writeln(r.output);
        enforceExitStatus(r.status, "compile");
        if (elapsed < m.wallMs)
            m.wallMs = elapsed;
        if (r.usage.peakRssBytes > m.peakRssBytes)
            m.peakRssBytes = r.usage.peakRssBytes;
        const cpuMs = r.usage.cpuTime.total!"msecs";
        if (cpuMs > m.cpuMs)
            m.cpuMs = cpuMs;
    }

    analyzeTrace(traceFile, m);
    countInstantiations(cmd[0 .. $ - 1], file, m);
    return m;
}

/// Fills the `-vtemplates` fields of `m` from one extra frontend pass, counting
/// instantiations of templates declared in the `sparkles.wired` modules.
void countInstantiations(const string[] baseCmd, string file, ref Metrics m)
{
    const r = execute(baseCmd.dup ~ ["-vtemplates", file]);
    if (r.status != 0)
        stderr.writeln(r.output);
    enforceExitStatus(r.status, "vtemplates pass");

    size_t[2][string] byName; // template name → [total, distinct]
    foreach (line; r.output.split('\n'))
    {
        if (!line.canFind("/sparkles/wired/") || !line.canFind("vtemplate:"))
            continue;
        // <file>(l,c): vtemplate: N (D distinct) instantiation(s) of template `name(args)` found
        const parts = line.split("vtemplate: ")[1].split(' ');
        const total = parts[0].to!size_t;
        const distinct = parts[1][1 .. $].to!size_t;
        const name = line.split('`')[1].templateBaseName;
        byName.update(name,
            () => cast(size_t[2])[total, distinct],
            (ref size_t[2] v) { v[0] += total; v[1] += distinct; });
    }
    m.instTotal = byName.byValue.map!(v => v[0]).sum;
    m.instDistinct = byName.byValue.map!(v => v[1]).sum;
    m.topInst = byName.byKeyValue
        .map!(kv => InstEntry(kv.key, kv.value[0], kv.value[1]))
        .array
        .sort!((a, b) => a.total > b.total)
        .release;
}

private enum templatePrefix = "Sema1: Template Instance ";
private enum ctfePrefix = "Ctfe: ";

/// Fills the trace-derived fields of `m` from a Chrome-trace JSON file.
void analyzeTrace(string traceFile, ref Metrics m)
{
    static string detailOf(JSONValue e)
    {
        if (auto args = "args" in e)
            if (auto d = "detail" in *args)
                return d.str;
        return "";
    }

    auto events = parseJSON(readText(traceFile))["traceEvents"].array
        .filter!(e => e["ph"].str == "X")
        .map!(e => TraceEvent(e["name"].str, detailOf(e), e["ts"].integer,
            e["ts"].integer + e["dur"].integer))
        .array;
    if (!events.length)
        return;

    m.frontendMs = (events.map!(e => e.end).maxElement
        - events.map!(e => e.start).minElement) / 1000;

    auto templates = events.filter!(e => e.name.startsWith(templatePrefix)).array;
    auto ctfes = events.filter!(e => e.name.startsWith(ctfePrefix)).array;
    m.templateCount = templates.length;
    m.ctfeCount = ctfes.length;
    m.templateMs = unionUs(templates) / 1000;
    m.ctfeMs = unionUs(ctfes) / 1000;

    // Group wired instantiations by their qualified template name (arguments
    // stripped) and union each group's intervals so self-recursion is not
    // double-counted. The event's `detail` carries the qualified name.
    TraceEvent[][string] byName;
    TraceEvent[][string] byPkg;
    foreach (e; templates)
    {
        byPkg[e.detail.rootPackage] ~= e;
        if (!e.detail.startsWith("sparkles.wired"))
            continue;
        byName[e.detail.templateBaseName] ~= e;
    }
    m.topWired = byName.byKeyValue
        .map!(kv => TopEntry(kv.key, unionUs(kv.value) / 1000, kv.value.length))
        .array
        .sort!((a, b) => a.ms > b.ms || (a.ms == b.ms && a.count > b.count))
        .release;
    m.byPackage = byPkg.byKeyValue
        .map!(kv => TopEntry(kv.key, unionUs(kv.value) / 1000, kv.value.length))
        .array
        .sort!((a, b) => a.ms > b.ms || (a.ms == b.ms && a.count > b.count))
        .release;
}

/// The root package of a qualified instantiation name — two dot-components for
/// the `std`/`core`/`sparkles` namespaces, one otherwise. Nested events count
/// toward every enclosing package's union, so shares can overlap.
string rootPackage(string detail)
{
    if (!detail.length)
        return "?";
    const parts = detail.split('.');
    if (parts.length >= 2
        && (parts[0] == "std" || parts[0] == "core" || parts[0] == "sparkles"))
        return parts[0] ~ "." ~ parts[1].templateBaseName;
    return parts[0].templateBaseName;
}

struct TraceEvent
{
    string name;
    string detail;
    long start;
    long end;
}

/// A qualified instantiation name up to its first template-argument list.
string templateBaseName(string full)
{
    foreach (i, c; full)
        if (c == '!' || c == '(')
            return full[0 .. i];
    return full;
}

/// Total microseconds covered by the union of the events' intervals.
long unionUs(TraceEvent[] events)
{
    auto iv = events.map!(e => [e.start, e.end]).array;
    iv.sort!((a, b) => a[0] < b[0]);
    long total, curStart = -1, curEnd = -1;
    foreach (i; iv)
    {
        if (i[0] > curEnd)
        {
            total += curEnd - curStart;
            curStart = i[0];
            curEnd = i[1];
        }
        else if (i[1] > curEnd)
            curEnd = i[1];
    }
    return total + (curEnd - curStart);
}

// ─────────────────────────────────────────────────────────────────────────────
// Reporting
// ─────────────────────────────────────────────────────────────────────────────

void report(Metrics m, uint top)
{
    writeln;
    format!"%s size=%s"(m.workload, m.size)
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 72))
        .writeln;

    // Scalar metrics as a two-row key/value table.
    string[] labels = ["wall", "frontend", "templates", "ctfe",
        "peak rss", "cpu", "wired insts"];
    string[] values = [
        format!"%s ms"(m.wallMs),
        format!"%s ms"(m.frontendMs),
        format!"%s ms (%s ev)"(m.templateMs, m.templateCount),
        format!"%s ms (%s ev)"(m.ctfeMs, m.ctfeCount),
        format!"%.1f MiB"(m.peakRssBytes / (1024.0 * 1024.0)),
        format!"%s ms"(m.cpuMs),
        format!"%s (%s distinct)"(m.instTotal, m.instDistinct),
    ];
    drawTable([labels, values]).write;

    if (m.topWired.length)
    {
        writeln("top sparkles.wired templates by time:");
        (["ms".stylize(Style.bold), "count".stylize(Style.bold),
                "template".stylize(Style.bold)]
            ~ m.topWired.head(top)
                .map!(t => [t.ms.to!string, t.count.to!string, t.name])
                .array)
            .drawTable.write;
    }
    if (m.topInst.length)
    {
        writeln("top sparkles.wired templates by instantiation count:");
        (["total".stylize(Style.bold), "distinct".stylize(Style.bold),
                "template".stylize(Style.bold)]
            ~ m.topInst.head(top)
                .map!(t => [t.total.to!string, t.distinct.to!string, t.name])
                .array)
            .drawTable.write;
    }
    if (m.byPackage.length)
    {
        writeln("template time by root package (unions overlap across nesting):");
        (["ms".stylize(Style.bold), "events".stylize(Style.bold),
                "package".stylize(Style.bold)]
            ~ m.byPackage.head(top)
                .map!(t => [t.ms.to!string, t.count.to!string, t.name])
                .array)
            .drawTable.write;
    }
}

/// The first `n` elements of `r`, or all of them when it is shorter.
auto head(R)(R r, size_t n) => r.length > n ? r[0 .. n] : r;
