#!/usr/bin/env dub
/+ dub.sdl:
    name "dql_compile_time_bench"

    dependency "sparkles:dql"      path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base"     path="../../.."

    dflags "-preview=in" "-preview=dip1000"
+/
/**
Compile-time benchmark for `DqlSchema` generation.

Generates synthetic subject-vocabulary modules of parameterized shape,
instantiates `DqlSchema` over each frontend-only (`-o-`) with LDC's
`-ftime-trace`, and reports where the compiler spent its time — wall clock,
peak resident-set size and CPU time of the compiler tree (via
`sparkles:core-cli`'s resource-monitored executor), template-instantiation and
CTFE totals (interval-union per category, so nested events are not
double-counted), event counts, and the top `sparkles.dql` /
`sparkles.reflection` templates by time. A separate `-vtemplates` pass counts
instantiations of those packages' templates — a deterministic signal for
validating refactorings, independent of timer noise.

Per-instance `Sema1: Template Instance` trace events need LDC ≥ 1.42; under
LDC 1.41 the template-time column reads 0 and the CTFE, wall, and
`-vtemplates` metrics still apply.

Workloads:
$(LIST
    * `sum`        — one `SumType` of N alternatives, each a struct of six
        fields cycling enum/bool/double/char/modifier-struct/value-like wrapper
    * `nested`     — transparent sums nested N levels deep, each level with
        declared fields $(B after) the sum field (the prefix-retention shape)
    * `real-input` — `DqlSchema!(sparkles.input.Event)` (ignores `--sizes`)
    * `real-wsi`   — `DqlSchema!(sparkles.wsi.WindowEvent)` (ignores `--sizes`)
)

Usage:
---
./compile-time-bench.d [--sizes=4,8,16] [--iters=3] \
    [--workloads=sum,nested,real-input,real-wsi] [--json=FILE] [--top=8] \
    [--dflags="-d-version=Foo"] [--keep]
---

Wall time is the minimum over `--iters` runs; trace-derived metrics come from
the last run (they are deterministic). Pass `--json` to dump the metrics for
before/after comparison of an optimization. Note the probes are compiled
$(B without) `-allinst`, unlike the unittest configuration, so the counts
reflect what a real consumer pays.
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
import std.range : iota;
import std.stdio : File, stderr, write, writefln, writeln;

import sparkles.base.logger : info, initLogger;
import sparkles.base.term_style : Style, stylize;

import sparkles.core_cli.args : Option, parseCli, reportCliError;
import sparkles.core_cli.help_formatting : HelpInfo;
import sparkles.core_cli.process_utils : enforceExitStatus, executeMonitored;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;
import sparkles.ui.components.table : drawTable;

import sparkles.wired.json : toJSON;

/// Command-line configuration, parsed by `sparkles:core-cli`.
struct BenchOptions
{
    @(Option("s|sizes", description:
        "Comma-separated workload sizes (default 4,8,16)"))
    string sizes = "4,8,16";

    @(Option("w|workloads", description:
        "Comma-separated workload names (default all)"))
    string workloads = "sum,nested,real-input,real-wsi";

    @(Option("i|iters", description:
        "Compile runs per data point; wall time is the minimum"))
    uint iters = 3;

    @(Option("t|top", description:
        "How many top templates to show per data point"))
    uint top = 8;

    @(Option("j|json", description: "Dump metrics as JSON to this file"))
    string json;

    @(Option("c|compiler", description:
        "D compiler to benchmark (must support -ftime-trace)"))
    string compiler = "ldc2";

    @(Option("d|dflags", description:
        "Extra space-separated flags for the probe compiles (e.g. -d-version=X)"))
    string dflags;

    @(Option("k|keep", description: "Keep the generated workload modules"))
    bool keep;
}

int main(string[] args)
{
    initLogger(LogLevel.info);

    auto parsed = parseCli!BenchOptions(args,
        HelpInfo("compile-time-bench",
            "Compile-time benchmark for DqlSchema generation."));
    if (!parsed)
        return reportCliError(parsed.error);
    const opts = parsed.value;

    const sizes = opts.sizes.split(',').map!(to!uint).array;
    const workloads = opts.workloads.split(',');
    const extraFlags = opts.dflags.split(' ').filter!(f => f.length).array;
    const importPaths = schemaImportPaths();
    const genDir = buildPath(tempDir, "dql-compile-bench");
    mkdirRecurse(genDir);
    scope (exit)
        if (!opts.keep)
            rmdirRecurse(genDir);

    Metrics[] results;
    foreach (workload; workloads)
        // The real-vocabulary workloads have a fixed shape; size 0 marks them.
        foreach (size; workload.startsWith("real-") ? [0u] : sizes)
        {
            info(i"benchmarking $(workload) size=$(size)");
            const name = format!"bench_%s_%s"(workload.sanitized, size);
            const file = buildPath(genDir, name ~ ".d");
            writeFile(file, generate(workload, name, size));

            auto m = measure(opts.compiler, file,
                buildPath(genDir, name ~ ".trace.json"), importPaths,
                extraFlags, opts.iters);
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

/// A workload name as a module-name fragment.
string sanitized(string workload)
    => workload.split('-').join('_');

/**
Import paths of `sparkles:dql` plus the real subject vocabularies
(`sparkles:input`, `sparkles:wsi`), resolved by dub from each package
directory. The vocabularies are unittest-only dependencies of dql, so their
paths do not appear in dql's own library-configuration describe output.
*/
string[] schemaImportPaths()
{
    const libsDir = __FILE_FULL_PATH__.dirName.dirName.dirName;
    bool[string] seen;
    string[] paths;
    foreach (pkg; ["dql", "input", "wsi"])
    {
        const r = execute(["dub", "describe", "--root", buildPath(libsDir, pkg),
            "--data=import-paths", "--data-list"]);
        if (r.status != 0)
            stderr.writeln(r.output);
        enforceExitStatus(r.status, "dub describe " ~ pkg);
        foreach (line; r.output.split('\n').filter!(l => l.length))
            if (line !in seen)
            {
                seen[line] = true;
                paths ~= line;
            }
    }
    return paths;
}

// ─────────────────────────────────────────────────────────────────────────────
// Workload generation
// ─────────────────────────────────────────────────────────────────────────────

/// The source of one synthetic module instantiating `DqlSchema` over a subject.
string generate(string workload, string moduleName, uint size)
{
    const header = "module " ~ moduleName ~ ";\n\n"
        ~ "import std.sumtype : SumType;\n\n"
        ~ "import sparkles.dql.schema : DqlSchema;\n"
        ~ "import sparkles.metadata : Aliases, Description, Name;\n\n";

    switch (workload)
    {
        case "sum": return header ~ genSum(size);
        case "nested": return header ~ genNested(size);
        case "real-input":
            return "module " ~ moduleName ~ ";\n\n"
                ~ "import sparkles.dql.schema : DqlSchema;\n"
                ~ "import sparkles.input : Event;\n\n"
                ~ anchor("Event");
        case "real-wsi":
            return "module " ~ moduleName ~ ";\n\n"
                ~ "import sparkles.dql.schema : DqlSchema;\n"
                ~ "import sparkles.wsi : WindowEvent;\n\n"
                ~ anchor("WindowEvent");
        default: throw new Exception("unknown workload: " ~ workload);
    }
}

/// The instantiation anchor: forcing both tables through `static assert`
/// makes the whole schema walk (and its CTFE evaluation) part of the compile.
private string anchor(string type)
{
    return "alias S = DqlSchema!(" ~ type ~ ");\n"
        ~ "static assert(S.paths.length > 0);\n"
        ~ "static assert(S.categories.length > 0);\n";
}

/// One `SumType` of `size` alternatives, each a struct of six fields cycling
/// through the leaf shapes the input/wsi vocabularies use: enums, bools,
/// floats, chars, a modifier aggregate, and a value-like wrapper. Every 4th
/// alternative carries `@Aliases`, every 5th `@Name`.
string genSum(uint size)
{
    string s = "enum Mode { alpha, beta, gamma, delta }\n\n"
        ~ "struct Mods { bool ctrl; bool alt; bool shift;"
        ~ " @Name(\"meta\") bool super_; }\n\n"
        ~ "struct Extent\n{\n"
        ~ "    private int value_;\n"
        ~ "    @property int value() const => value_;\n"
        ~ "}\n\n";

    foreach (i; 0 .. size)
    {
        if (i % 5 == 4)
            s ~= format!"@Name(\"alt%s\")\n"(i);
        else if (i % 4 == 3)
            s ~= format!"@Aliases(\"a%s\")\n"(i);
        s ~= format!"struct Alt%sEvent\n{\n"(i);
        foreach (f; 0 .. 6)
        {
            final switch ((i + f) % 6)
            {
                case 0: s ~= format!"    Mode mode%s;\n"(f); break;
                case 1: s ~= format!"    bool active%s;\n"(f); break;
                case 2: s ~= format!"    double weight%s;\n"(f); break;
                case 3: s ~= format!"    char tag%s;\n"(f); break;
                case 4: s ~= format!"    Mods mods%s;\n"(f); break;
                case 5: s ~= format!"    Extent extent%s;\n"(f); break;
            }
        }
        s ~= "}\n\n";
    }

    s ~= "alias Subject = SumType!(\n"
        ~ size.iota.map!(i => format!"    Alt%sEvent,\n"(i)).join
        ~ ");\n\n";
    return s ~ anchor("Subject");
}

/// Transparent sums nested `size` levels deep. Every level declares fields
/// $(B after) its sum field — the shape where the enclosing variant prefix
/// must survive the nested sum's completion.
string genNested(uint size)
{
    string s = "struct LeafEvent { int value; bool flag; }\n\n";
    foreach_reverse (lvl; 0 .. size)
    {
        s ~= format!"struct Stop%sEvent { bool forced%s; }\n"(lvl, lvl);
        s ~= format!"struct Host%sEvent\n{\n"(lvl);
        const inner = lvl + 1 < size
            ? format!"Host%sEvent"(lvl + 1) : "LeafEvent";
        s ~= format!"    SumType!(%s, Stop%sEvent) inner%s;\n"(inner, lvl, lvl);
        s ~= format!"    int after%s;\n    bool tail%s;\n"(lvl, lvl);
        s ~= "}\n\n";
    }
    s ~= "alias Subject = SumType!(Host0Event, LeafEvent);\n\n";
    return s ~ anchor("Subject");
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
    size_t instTotal;       /// -vtemplates: total dql/reflection instantiations
    size_t instDistinct;    /// -vtemplates: distinct dql/reflection instantiations
    TopEntry[] topDql;      /// top dql/reflection templates by unioned time
    InstEntry[] topInst;    /// top dql/reflection templates by instantiation count
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
    const string[] importPaths, const string[] extraFlags, uint iters)
{
    const cmd = [compiler, "-c", "-o-", "-preview=in", "-preview=dip1000"]
        ~ extraFlags.dup
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

/// `true` for a path or qualified name inside the packages under measurement.
private bool isMeasuredPath(string line)
    => line.canFind("/sparkles/dql/") || line.canFind("/sparkles/reflection/");

/// ditto, for a qualified instantiation name.
private bool isMeasuredName(string detail)
    => detail.startsWith("sparkles.dql")
        || detail.startsWith("sparkles.reflection");

/// Fills the `-vtemplates` fields of `m` from one extra frontend pass, counting
/// instantiations of templates declared in the measured packages.
void countInstantiations(const string[] baseCmd, string file, ref Metrics m)
{
    const r = execute(baseCmd.dup ~ ["-vtemplates", file]);
    if (r.status != 0)
        stderr.writeln(r.output);
    enforceExitStatus(r.status, "vtemplates pass");

    size_t[2][string] byName; // template name → [total, distinct]
    foreach (line; r.output.split('\n'))
    {
        if (!line.isMeasuredPath || !line.canFind("vtemplate:"))
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

    // Group measured-package instantiations by their qualified template name
    // (arguments stripped) and union each group's intervals so self-recursion
    // is not double-counted. The event's `detail` carries the qualified name.
    TraceEvent[][string] byName;
    TraceEvent[][string] byPkg;
    foreach (e; templates)
    {
        byPkg[e.detail.rootPackage] ~= e;
        if (!e.detail.isMeasuredName)
            continue;
        byName[e.detail.templateBaseName] ~= e;
    }
    m.topDql = byName.byKeyValue
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
        "peak rss", "cpu", "dql insts"];
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

    if (m.topDql.length)
    {
        writeln("top dql/reflection templates by time:");
        (["ms".stylize(Style.bold), "count".stylize(Style.bold),
                "template".stylize(Style.bold)]
            ~ m.topDql.head(top)
                .map!(t => [t.ms.to!string, t.count.to!string, t.name])
                .array)
            .drawTable.write;
    }
    if (m.topInst.length)
    {
        writeln("top dql/reflection templates by instantiation count:");
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
