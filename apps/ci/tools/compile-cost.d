#!/usr/bin/env dub
/+ dub.sdl:
    name "compile_cost"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:wired" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Measures what one root-package compile costs, with dependencies warm.

For each target and compiler, dub captures the root package's own compile
command (`dub <verb> -v`, after touching the recipe so the root is stale);
the command is then replayed, object output redirected to the work directory,
`--runs` times. Each run reports the instructions the compiler retired in user
space (`perf stat`, when perf counters are available), its user and system CPU
time, wall time and peak RSS (`wait4`). The machine may be shared and loaded:
compare instructions and CPU time, not wall time.

`--trace` adds one `-ftime-trace` run at a coarse granularity and prints the
top events by self and by inclusive time (an event nested inside an event of
the same name counts once); `--vtemplates` adds one `-vtemplates -o-` run and
prints the most-instantiated templates.

Targets:
$(LIST
    * `bp-test` — `dub test :build-primitives`'s test root
    * `bp-lib` — the build-primitives library, as a dependent rebuilds it
    * `manifest-call` — a program whose `main` calls `parseDubManifest`
    * `manifest-decode` — a program instantiating `fromSDL!(DubManifest, sdlDubRecipe)`
    * `ci-test`, `dmd-lsp-test` — those packages' test roots
)

Usage:
---
apps/ci/tools/compile-cost.d [--compilers=dmd,ldc2] [--targets=bp-test,…]
    [--runs=3] [--frontend-only] [--trace] [--granularity=20000]
    [--vtemplates] [--top=15] [--work=DIR] [--json=FILE]
---
Run from the repository root, inside the dev shell.
*/
module compile_cost;

import core.sys.posix.sys.resource : rusage;
import core.sys.posix.sys.wait : WEXITSTATUS, WIFEXITED;

import std.algorithm : canFind, endsWith, filter, map, max, min, sort, startsWith;
import std.array : array, join, replace, split;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, remove, setTimes, write;
import std.format : format;
import std.getopt : getopt;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.process : Config, execute, spawnProcess;
import std.stdio : File, stderr, writefln, writeln;
import std.string : indexOf, lineSplitter, strip;
import std.datetime.systime : Clock;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.build_primitives.dub_manifest : DubDependency, DubManifest, DubPlatformValues;
import sparkles.wired.sdl : toSDL, writeEmbeddedRecipe;

extern (C) int wait4(int pid, int* status, int options, rusage* usage) nothrow @nogc;

private struct Target
{
    string name;
    string[] dubArgs; /// after `dub`, before `--compiler`
    string stale;     /// a file to touch so the root package recompiles
    bool library;     /// the root is a library: its compile is the `-lib` one
}

private struct Sample
{
    long instructions = -1;
    double user = 0, sys = 0, wall = 0;
    long maxRssKiB;
}

private struct Measurement
{
    string target, compiler;
    bool frontendOnly;
    Sample[] samples;
}

int main(string[] args)
{
    string compilers = "dmd,ldc2";
    string targets = "bp-test,bp-lib,manifest-call,manifest-decode,ci-test,dmd-lsp-test";
    uint runs = 3, top = 15, granularity = 20_000;
    bool frontendOnly, trace, vtemplates;
    string work = "build/compile-cost", jsonPath;
    getopt(args,
        "compilers", &compilers, "targets", &targets, "runs", &runs,
        "frontend-only", &frontendOnly, "trace", &trace,
        "granularity", &granularity, "vtemplates", &vtemplates, "top", &top,
        "work", &work, "json", &jsonPath);

    const root = absolutePath(".").buildNormalizedPath;
    enforce(exists(buildPath(root, "dub.sdl")) && exists(buildPath(root, "libs/wired")),
        "run from the sparkles repository root");
    work = absolutePath(work);
    mkdirRecurse(work);

    Measurement[] all;
    foreach (compiler; compilers.split(","))
        foreach (name; targets.split(","))
        {
            const target = targetNamed(name, root, work);
            auto command = capture(target, compiler, root, work);
            if (frontendOnly)
                command ~= "-o-";
            Measurement m = {target: name, compiler: compiler, frontendOnly: frontendOnly};
            foreach (run; 0 .. runs)
                m.samples ~= measure(command, root, work);
            report(m);
            all ~= m;
            if (trace)
                reportTrace(command, compiler, root,
                    buildPath(work, name ~ "-" ~ compiler ~ ".trace.json"), granularity, top);
            if (vtemplates)
                reportTemplates(command, root, top);
        }

    if (jsonPath.length)
    {
        JSONValue[] rows;
        foreach (m; all)
            foreach (s; m.samples)
                rows ~= JSONValue([
                    "target": JSONValue(m.target), "compiler": JSONValue(m.compiler),
                    "frontendOnly": JSONValue(m.frontendOnly),
                    "instructions": JSONValue(s.instructions), "user": JSONValue(s.user),
                    "sys": JSONValue(s.sys), "wall": JSONValue(s.wall),
                    "maxRssKiB": JSONValue(s.maxRssKiB),
                ]);
        File(jsonPath, "w").writeln(JSONValue(rows).toPrettyString);
    }
    return 0;
}

private Target targetNamed(string name, string root, string work)
{
    switch (name)
    {
    case "bp-test":
        return Target(name, ["test", ":build-primitives"], "libs/build-primitives/dub.sdl");
    case "bp-lib":
        return Target(name, ["build", ":build-primitives"], "libs/build-primitives/dub.sdl", true);
    case "ci-test":
        return Target(name, ["test", ":ci"], "apps/ci/dub.sdl");
    case "dmd-lsp-test":
        return Target(name, ["test", ":dmd-lsp"], "libs/dmd-lsp/dub.sdl");
    case "manifest-call":
        return singleFile(name, work, root, "import sparkles.build_primitives.dub_manifest;\n\n"
            ~ "int main() => parseDubManifest(`name \"x\"`).hasValue ? 0 : 1;\n");
    case "manifest-decode":
        return singleFile(name, work, root, "import sparkles.build_primitives.dub_manifest;\n"
            ~ "import sparkles.wired.sdl : fromSDL, sdlDubRecipe;\n\n"
            ~ "int main() => fromSDL!(DubManifest, sdlDubRecipe)(`name \"x\"`).hasValue ? 0 : 1;\n");
    default:
        throw new Exception("unknown target: " ~ name);
    }
}

// A single-file package in the git-ignored `build/compile-cost/`, depending on
// build-primitives as every in-repository example does: by relative path.
private Target singleFile(string name, string work, string root, string body_)
{
    const dir = buildPath(root, "build", "compile-cost");
    mkdirRecurse(dir);
    const path = buildPath(dir, name.replace("-", "_") ~ ".d");
    DubManifest manifest = {name: name.replace("-", "_")};
    manifest.dependencies = [DubDependency(name: "sparkles:build-primitives", path: "../..")];
    manifest.dflags = [DubPlatformValues(values: ["-preview=in", "-preview=dip1000"])];
    const recipe = toSDL(manifest);
    enforce(recipe.hasValue, "cannot encode the probe recipe");
    UniqueBuffer!char header;
    writeEmbeddedRecipe(header, recipe.value[]);
    const source = header[].idup ~ body_;
    if (!exists(path) || readText(path) != source)
        write(path, source);
    return Target(name, ["build", "--single", path], path);
}

/// The root package's compile command, its object redirected into `work`.
private string[] capture(in Target target, string compiler, string root, string work)
{
    const cache = buildPath(work, target.name ~ "-" ~ compiler ~ ".command");
    if (exists(cache))
        return readText(cache).strip.split(" ");

    const stale = target.stale.startsWith("/") ? target.stale : buildPath(root, target.stale);
    const now = Clock.currTime;
    setTimes(stale, now, now);
    auto args = ["dub"] ~ target.dubArgs ~ ["--compiler=" ~ compiler, "-v"];
    if (target.dubArgs[0] == "test")
        args ~= ["--", "--list"];
    const r = execute(args, null, Config.none, size_t.max, root);
    string[] command;
    foreach (line; r.output.lineSplitter)
    {
        // dub prefixes a command with its directory when that is not the
        // root's (dmd), and prints it bare otherwise (ldc2).
        string text;
        if (line.startsWith("[cwd="))
            text = line[line.indexOf("] ") + 2 .. $];
        else if (line.startsWith(compiler ~ " "))
            text = line;
        else
            continue;
        auto words = text.split(" ").filter!(w => w.length).array;
        if (target.library ? words.canFind("-lib") : words.canFind("-c") && !words.canFind("-lib"))
            command = words;
    }
    if (command.length == 0)
    {
        stderr.writeln(r.output);
        throw new Exception("no root compile command in `" ~ args.join(" ") ~ "`");
    }
    const object = buildPath(work, target.name ~ "-" ~ compiler ~ ".o");
    foreach (ref w; command)
        if (w.startsWith("-of"))
            w = "-of" ~ object;
    // dub states each dflag once per dependency; once is enough.
    string[] unique;
    foreach (w; command)
        if (!(w.startsWith("-") && !w.startsWith("-I") && !w.startsWith("-version=")
                && unique.canFind(w)))
            unique ~= w;
    write(cache, unique.join(" "));
    return unique;
}

private Sample measure(string[] command, string root, string work)
{
    const perfOut = buildPath(work, "perf.csv");
    const havePerf = execute(["perf", "stat", "-x,", "-e", "instructions:u", "true"]).status == 0;
    auto argv = havePerf
        ? ["perf", "stat", "-x,", "-o", perfOut, "-e", "instructions:u", "--"] ~ command
        : command;

    Sample s;
    auto clock = StopWatch(AutoStart.yes);
    auto pid = spawnProcess(argv, null, Config.none, root);
    int status;
    rusage usage;
    enforce(wait4(pid.processID, &status, 0, &usage) == pid.processID, "wait4 failed");
    s.wall = clock.peek.total!"usecs" / 1e6;
    enforce(WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "compile failed: " ~ command.join(" "));
    s.user = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6;
    s.sys = usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
    s.maxRssKiB = usage.ru_maxrss;
    if (havePerf)
        foreach (line; readText(perfOut).lineSplitter)
        {
            const fields = line.split(",");
            if (fields.length > 2 && fields[2].startsWith("instructions"))
                s.instructions = fields[0].to!long;
        }
    return s;
}

private void report(in Measurement m)
{
    double best(double delegate(in Sample) f)
    {
        double b = double.infinity;
        foreach (s; m.samples)
            b = min(b, f(s));
        return b;
    }

    writefln!"%-16s %-5s %s  instr %8.2f G   user %6.2f s   sys %5.2f s   wall %6.2f s   rss %6.0f MiB   (min of %s)"(
        m.target, m.compiler, m.frontendOnly ? "-o-" : "   ",
        best(s => s.instructions) / 1e9, best(s => s.user), best(s => s.sys),
        best(s => s.wall), best(s => s.maxRssKiB) / 1024.0, m.samples.length);
}

private struct Event
{
    string key;
    long ts, dur;
}

private struct Totals
{
    long self, inclusive, count;
}

private void reportTrace(string[] command, string compiler, string root, string file,
    uint granularity, uint top)
{
    const ldc = compiler.canFind("ldc");
    auto argv = command.filter!(w => w != "-o-").array ~ ["-o-",
        (ldc ? "--" : "-") ~ "ftime-trace",
        (ldc ? "--" : "-") ~ "ftime-trace-file=" ~ file,
        (ldc ? "--" : "-") ~ "ftime-trace-granularity=" ~ granularity.to!string];
    const r = execute(argv, null, Config.none, size_t.max, root);
    enforce(r.status == 0, r.output);

    // One event per line: parse the complete (`X`) events only.
    Event[][long] byThread;
    foreach (line; File(file).byLineCopy)
    {
        if (!line.canFind(`"ph":"X"`))
            continue;
        auto text = line.strip;
        if (text.endsWith(","))
            text = text[0 .. $ - 1];
        const j = parseJSON(text);
        string key = j["name"].str;
        if (const args = "args" in j)
            if (const detail = "detail" in *args)
                if (detail.str.length && !key.canFind(detail.str))
                    key ~= " " ~ detail.str;
        byThread[j["tid"].integer] ~= Event(key, j["ts"].integer, j["dur"].integer);
    }

    Totals[string] totals;
    foreach (events; byThread.byValue)
    {
        events.sort!((a, b) => a.ts != b.ts ? a.ts < b.ts : a.dur > b.dur);
        size_t[] stack; // indices into events
        long[] childTime;
        void pop()
        {
            const e = events[stack[$ - 1]];
            auto t = &totals.require(e.key, Totals.init);
            t.self += e.dur - childTime[$ - 1];
            t.count++;
            // Recursion: an ancestor of the same key already covers this one.
            bool nested;
            foreach (i; stack[0 .. $ - 1])
                nested |= events[i].key == e.key;
            if (!nested)
                t.inclusive += e.dur;
            stack = stack[0 .. $ - 1];
            childTime = childTime[0 .. $ - 1];
            if (childTime.length)
                childTime[$ - 1] += e.dur;
        }

        foreach (i, e; events)
        {
            while (stack.length && events[stack[$ - 1]].ts + events[stack[$ - 1]].dur <= e.ts)
                pop();
            stack ~= i;
            childTime ~= 0;
        }
        while (stack.length)
            pop();
    }

    auto keys = totals.keys;
    void table(string title, long delegate(in Totals) f)
    {
        keys.sort!((a, b) => f(totals[a]) > f(totals[b]));
        writefln!"  top %s by %s (granularity %s µs):"(top, title, granularity);
        foreach (k; keys[0 .. min(top, $)])
            writefln!"    %8.2f s  %5s×  %s"(f(totals[k]) / 1e6, totals[k].count,
                k.length > 160 ? k[0 .. 157] ~ "..." : k);
    }

    table("self time", t => t.self);
    table("inclusive time", t => t.inclusive);
}

private void reportTemplates(string[] command, string root, uint top)
{
    auto argv = command.filter!(w => w != "-o-").array ~ ["-o-", "-vtemplates"];
    const r = execute(argv, null, Config.none, size_t.max, root);
    enforce(r.status == 0, r.output);
    struct Row
    {
        long count, distinct;
        string name;
    }

    Row[] rows;
    long total, distinct;
    foreach (line; r.output.lineSplitter)
    {
        // `…: vtemplate: 123 (45 distinct) instantiation(s) of template `name(…)` found`
        const at = line.indexOf("vtemplate: ");
        if (at < 0)
            continue;
        auto rest = line[at + "vtemplate: ".length .. $];
        const count = rest[0 .. rest.indexOf(" ")].to!long;
        const open = rest.indexOf("(");
        const d = rest[open + 1 .. rest.indexOf(" distinct")].to!long;
        const tick = rest.indexOf("`");
        auto name = rest[tick + 1 .. $];
        name = name[0 .. max(0, name.indexOf("`"))];
        rows ~= Row(count, d, name);
        total += count;
        distinct += d;
    }
    rows.sort!((a, b) => a.distinct > b.distinct);
    writefln!"  -vtemplates: %s instantiations, %s distinct; top %s by distinct:"(total, distinct, top);
    foreach (row; rows[0 .. min(top, $)])
        writefln!"    %7s distinct  %8s total  %s"(row.distinct, row.count,
            row.name.length > 140 ? row.name[0 .. 137] ~ "..." : row.name);
}
