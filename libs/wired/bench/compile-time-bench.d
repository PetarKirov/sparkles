#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_compile_time_bench"
+/
/**
Compile-time benchmark for `sparkles:wired`.

Generates synthetic consumer modules of parameterized shape and size, compiles
each frontend-only (`-o-`) with LDC's `-ftime-trace`, and reports where the
compiler spent its time — wall clock, template-instantiation and CTFE totals
(interval-union per category, so nested events are not double-counted), event
counts, and the top `sparkles.wired` templates by time. A separate
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
import std.array : array, join, replace, split;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : execute;
import std.range : iota;
import std.stdio : File, writefln, writeln;

int main(string[] args)
{
    string sizesArg = "8,32,128";
    string workloadsArg = "wide,deep,enums,mixed";
    string jsonOut;
    string compiler = "ldc2";
    uint iters = 3;
    uint top = 8;
    bool keep;

    auto opts = getopt(args,
        "sizes", "Comma-separated workload sizes (default 8,32,128)", &sizesArg,
        "workloads", "Comma-separated workload names (default all)", &workloadsArg,
        "iters", "Compile runs per data point; wall time is the minimum", &iters,
        "top", "How many top templates to show per data point", &top,
        "json", "Dump metrics as JSON to this file", &jsonOut,
        "compiler", "D compiler to benchmark (must support -ftime-trace)", &compiler,
        "keep", "Keep the generated workload modules", &keep,
    );
    if (opts.helpWanted)
    {
        defaultGetoptPrinter("Compile-time benchmark for sparkles:wired.", opts.options);
        return 0;
    }

    const sizes = sizesArg.split(',').map!(to!uint).array;
    const workloads = workloadsArg.split(',');
    const importPaths = wiredImportPaths();
    const genDir = buildPath(tempDir, "wired-compile-bench");
    mkdirRecurse(genDir);
    scope (exit)
        if (!keep)
            rmdirRecurse(genDir);

    JSONValue[] results;
    foreach (workload; workloads)
        foreach (size; sizes)
        {
            const name = format!"bench_%s_%s"(workload, size);
            const file = buildPath(genDir, name ~ ".d");
            write(file, generate(workload, name, size));

            const m = measure(compiler, file, buildPath(genDir, name ~ ".trace.json"),
                importPaths, iters);
            report(workload, size, m, top);
            results ~= m.toJSON(workload, size);
        }

    if (jsonOut.length)
    {
        File(jsonOut, "w").writeln(JSONValue(results).toPrettyString);
        writefln!"\nmetrics written to %s"(jsonOut);
    }
    if (keep)
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
    enforce(r.status == 0, "dub describe failed:\n" ~ r.output);
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

/// The encode + decode instantiation anchor for the root type.
private string anchor(string type)
{
    return "\nJsonResult!JSONValue enc(in " ~ type ~ " v) => toJSON(v);\n"
        ~ "JsonResult!" ~ type ~ " dec(JSONValue j) => fromJSON!" ~ type ~ "(j);\n";
}

/// One struct, `size` scalar/string fields; every 4th field renamed, every 6th
/// optional — the shape of a large flat config aggregate.
string genWide(uint size)
{
    string s = "@WireCase!Json(CaseStyle.snakeCase)\nstruct Wide\n{\n";
    static immutable types = ["int", "string", "double", "bool"];
    foreach (i; 0 .. size)
    {
        if (i % 4 == 3)
            s ~= format!"    @WireName!Json(\"wire%s\")\n"(i);
        if (i % 6 == 5)
            s ~= "    @WireOptional()\n";
        s ~= format!"    %s someField%s;\n"(types[i % $], i);
    }
    return s ~ "}\n" ~ anchor("Wide");
}

/// A chain of `size` nested structs; every 4th level recased, every 3rd field
/// renamed — the shape of a deeply structured document.
string genDeep(uint size)
{
    string s;
    foreach_reverse (lvl; 0 .. size)
    {
        if (lvl % 4 == 1)
            s ~= "@WireCase!Json(CaseStyle.snakeCase)\n";
        s ~= format!"struct Level%s\n{\n"(lvl);
        if (lvl % 3 == 2)
            s ~= format!"    @WireName!Json(\"depth%s\")\n"(lvl);
        s ~= format!"    int payloadValue%s;\n    string labelText%s;\n"(lvl, lvl);
        if (lvl + 1 < size)
            s ~= format!"    Level%s child;\n"(lvl + 1);
        s ~= "}\n\n";
    }
    return s ~ anchor("Level0");
}

/// `size / 4` enums of 8 members each, used as plain fields, array elements,
/// and AA keys — the shape that exercises name resolution and the slot lattice.
string genEnums(uint size)
{
    const nEnums = size < 4 ? 1 : size / 4;
    string s;
    foreach (e; 0 .. nEnums)
    {
        if (e % 2 == 0)
            s ~= "@WireCase!Json(CaseStyle.snakeCase)\n";
        if (e % 3 == 2)
            s ~= "@WireRepr!Json(Repr.value)\n";
        s ~= format!"enum Choice%s\n{\n"(e);
        foreach (m; 0 .. 8)
        {
            if (e == 0 && m % 4 == 3)
                s ~= format!"    @WireName!Json(\"alias%s\")\n"(m);
            s ~= format!"    optionValue%s,\n"(m);
        }
        s ~= "}\n\n";
    }

    s ~= "struct Enums\n{\n";
    foreach (e; 0 .. nEnums)
    {
        s ~= format!"    Choice%s plain%s;\n"(e, e);
        if (e % 2 == 1)
            s ~= format!"    @WireCase!Json(CaseStyle.kebabCase, WireTarget.value)\n"();
        s ~= format!"    Choice%s[] list%s;\n"(e, e);
        if (e % 3 != 2) // value-repr enums as AA keys need no name uniqueness
            s ~= format!"    int[Choice%s] table%s;\n"(e, e);
    }
    return s ~ "}\n" ~ anchor("Enums");
}

/// `size` fields cycling through wrappers, sum types, enums, arrays, AA keys,
/// converts, and small nested structs — the shape of a realistic API payload.
string genMixed(uint size)
{
    string s = "enum Kind { alphaMode, betaMode, gammaMode }\n\n"
        ~ "struct Point\n{\n    double xCoord;\n    double yCoord;\n}\n\n"
        ~ "@WireCase!Json(CaseStyle.snakeCase)\nstruct Mixed\n{\n";
    foreach (i; 0 .. size)
    {
        final switch (i % 9)
        {
            case 0: s ~= format!"    long counterValue%s;\n"(i); break;
            case 1: s ~= format!"    @WireOptional() Nullable!int maybeInt%s;\n"(i); break;
            case 2: s ~= format!"    @WireOptional(WireSkip.whenDefault) Optional!string maybeText%s;\n"(i); break;
            case 3: s ~= format!"    @(WireMatch.first!Json) SumType!(long, string) either%s;\n"(i); break;
            case 4: s ~= format!"    @WireConvert!(d => d.total!\"msecs\", ms => msecs(ms)) Duration timeout%s;\n"(i); break;
            case 5: s ~= format!"    @WireName!Json(\"kind%s\") Kind kindTag%s;\n"(i, i); break;
            case 6: s ~= format!"    @WireCase!Json(CaseStyle.kebabCase, WireTarget.value) Kind[] kindList%s;\n"(i); break;
            case 7: s ~= format!"    int[Kind] kindTable%s;\n"(i); break;
            case 8: s ~= format!"    Point position%s;\n"(i); break;
        }
    }
    return s ~ "}\n" ~ anchor("Mixed");
}

// ─────────────────────────────────────────────────────────────────────────────
// Measurement
// ─────────────────────────────────────────────────────────────────────────────

struct Metrics
{
    long wallMs;            /// best-of-iters wall clock of the whole compile
    long frontendMs;        /// span of all trace events (≈ frontend time)
    long templateMs;        /// interval-union of template-instantiation events
    long ctfeMs;            /// interval-union of CTFE events
    size_t templateCount;   /// number of template-instantiation events
    size_t ctfeCount;       /// number of CTFE events
    size_t instTotal;       /// -vtemplates: total wired-template instantiations
    size_t instDistinct;    /// -vtemplates: distinct wired-template instantiations
    TopEntry[] topWired;    /// top sparkles.wired templates by unioned time
    InstEntry[] topInst;    /// top sparkles.wired templates by instantiation count

    JSONValue toJSON(string workload, uint size) const
    {
        return JSONValue([
            "workload": JSONValue(workload),
            "size": JSONValue(size),
            "wallMs": JSONValue(wallMs),
            "frontendMs": JSONValue(frontendMs),
            "templateMs": JSONValue(templateMs),
            "ctfeMs": JSONValue(ctfeMs),
            "templateCount": JSONValue(templateCount),
            "ctfeCount": JSONValue(ctfeCount),
            "instTotal": JSONValue(instTotal),
            "instDistinct": JSONValue(instDistinct),
            "topWired": JSONValue(topWired.map!(t =>
                JSONValue(["name": JSONValue(t.name), "ms": JSONValue(t.ms),
                    "count": JSONValue(t.count)])).array),
            "topInst": JSONValue(topInst.map!(t =>
                JSONValue(["name": JSONValue(t.name), "total": JSONValue(t.total),
                    "distinct": JSONValue(t.distinct)])).array),
        ]);
    }
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
        const r = execute(cmd);
        const elapsed = sw.peek.total!"msecs";
        enforce(r.status == 0, "compile failed:\n" ~ r.output);
        if (elapsed < m.wallMs)
            m.wallMs = elapsed;
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
    enforce(r.status == 0, "compile failed:\n" ~ r.output);

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
    import std.file : readText;

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
    foreach (e; templates)
    {
        if (!e.detail.startsWith("sparkles.wired"))
            continue;
        byName[e.detail.templateBaseName] ~= e;
    }
    m.topWired = byName.byKeyValue
        .map!(kv => TopEntry(kv.key, unionUs(kv.value) / 1000, kv.value.length))
        .array
        .sort!((a, b) => a.ms > b.ms || (a.ms == b.ms && a.count > b.count))
        .release;
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

void report(string workload, uint size, in Metrics m, uint top)
{
    writefln!"\n%s size=%s: wall %s ms | frontend %s ms | templates %s ms (%s events) | ctfe %s ms (%s events) | wired insts %s (%s distinct)"(
        workload, size, m.wallMs, m.frontendMs,
        m.templateMs, m.templateCount, m.ctfeMs, m.ctfeCount,
        m.instTotal, m.instDistinct);
    foreach (t; m.topWired.length > top ? m.topWired[0 .. top] : m.topWired)
        writefln!"    %6s ms  %5s×  %s"(t.ms, t.count, t.name);
    foreach (t; m.topInst.length > top ? m.topInst[0 .. top] : m.topInst)
        writefln!"    %6s insts (%s distinct)  %s"(t.total, t.distinct, t.name);
}
