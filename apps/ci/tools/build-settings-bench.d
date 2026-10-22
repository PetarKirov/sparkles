#!/usr/bin/env dub
/+ dub.sdl:
    name "build_settings_bench"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Replay actual LDC root compile/link commands, with warm dependencies and no
test execution in build timings. See docs/guidelines/build-settings.md.

Capture with `dub test :pkg --force --verbose -- --help > capture.txt 2>&1`.
Run from the same working directory. Only replay trusted captures, without
whitespace in paths. Output retains commands, exit codes, logs and JSON samples.
BUILD_STUDY_VARIANTS selects comma-separated variants instead of the full matrix.
BUILD_STUDY_WILD_DIR names a directory containing an ld symlink to Wild.
BUILD_STUDY_CPU selects the runtime CPU (default 4); builds remain unpinned.
*/
module build_settings_bench;

import std.algorithm : canFind, endsWith, filter, startsWith;
import std.array : array, join, split;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.file : exists, getSize, mkdirRecurse, readText, write;
import std.json : JSONValue, parseJSON;
import std.process : environment, execute, executeShell;
import std.stdio : File, writeln;
import std.string : lineSplitter;

private struct Commands
{
    string[] compile, link;
    string object;
    string[][] graph;
}

private Commands commandsFrom(string capture) @safe
{
    Commands result;
    foreach (line; capture.lineSplitter)
    {
        if (!line.startsWith("ldc2 ")) continue;
        assert(!line.canFind('"') && !line.canFind('\''), "quoted paths are not supported");
        auto tokens = line.split;
        if (tokens.canFind("-lib") || tokens.canFind("-c") || tokens[1].startsWith("-of"))
            result.graph ~= tokens;
        if (tokens.canFind("-c")) result.compile = tokens;
        else if (tokens[1].startsWith("-of")) result.link = tokens;
    }
    assert(result.compile.length && result.link.length, "need verbose LDC compile and link commands");
    foreach (t; result.compile) if (t.startsWith("-of")) result.object = t[3 .. $];
    assert(result.object.endsWith(".o"));
    return result;
}

/// Root commands are selected independently of dependency compilation commands.
@("buildSettings.commandsFrom.root")
@safe unittest
{
    const c = commandsFrom("ldc2 -lib dependency.d -ofdep.a\n"
        ~ "ldc2 -g -c root.d -ofroot.o\nldc2 -ofbin root.o dep.a\n");
    assert(c.compile == ["ldc2", "-g", "-c", "root.d", "-ofroot.o"]);
    assert(c.object == "root.o");
    assert(c.link == ["ldc2", "-ofbin", "root.o", "dep.a"]);
    assert(c.graph.length == 3);
}

// Replays dependency archives too, into the captured DUB cache paths. Never run
// concurrently with another build using those caches. DUB setup and suite runtime
// stay outside the sum; compiler-invoked archiving is part of compilation.
private int compareGraph(string[] args) @system
{
    assert(args.length == 6, "--compare-graph baseline-capture selected-capture output-dir rounds");
    auto graphs = [commandsFrom(args[2].readText).graph, commandsFrom(args[3].readText).graph];
    const outputDir = args[4];
    outputDir.mkdirRecurse;
    auto samples = File(outputDir ~ "/samples.jsonl", "a");
    foreach (round; 0 .. args[5].to!uint)
    foreach (offset; 0 .. 2)
    {
        const selected = (round + offset) % 2;
        const variant = selected ? "selected" : "baseline";
        long compileMs, linkMs;
        JSONValue[] steps;
        foreach (index, command; graphs[selected])
        {
            const stem = outputDir ~ "/" ~ variant ~ "-" ~ round.to!string ~ "-" ~ index.to!string;
            (stem ~ ".command").write(command.join(" ") ~ "\n");
            auto timer = StopWatch();
            timer.start;
            auto r = execute(command);
            timer.stop;
            const ms = timer.peek.total!"msecs";
            const isLink = command[1].startsWith("-of");
            if (isLink) linkMs += ms; else compileMs += ms;
            (stem ~ ".log").write(r.output);
            JSONValue step;
            step["index"] = index;
            step["phase"] = isLink ? "link" : "compile";
            step["ms"] = ms;
            step["exit"] = r.status;
            steps ~= step;
            assert(r.status == 0, r.output);
        }
        JSONValue sample;
        sample["variant"] = variant;
        sample["round"] = round;
        sample["compileMs"] = compileMs;
        sample["compileExit"] = 0;
        sample["linkMs"] = linkMs;
        sample["linkExit"] = 0;
        sample["steps"] = steps;
        samples.writeln(sample.toString);
        samples.flush;
        writeln(sample.toString);
    }
    return 0;
}

private string benchmarkError(in JSONValue report) @safe
{
    if (!report["rows"].arrayNoRef.length) return "no benchmark cases measured";
    foreach (row; report["rows"].arrayNoRef)
        if (row["error"].str.length) return "benchmark row failed: " ~ row["error"].str;
    return null;
}

/// A successful process with no measured cases is not a successful experiment.
@("buildSettings.benchmarkReport.rejectsEmptyAndErrors")
@safe unittest
{
    assert(benchmarkError(parseJSON(`{"rows":[]}`)).length);
    assert(benchmarkError(parseJSON(`{"rows":[{"error":"bad result"}]}`)).length);
    assert(!benchmarkError(parseJSON(`{"rows":[{"error":""}]}`)).length);
}

private int compare(string[] args) @system
{
    assert(args.length >= 6, "--compare output-dir baseline-bin selected-bin rounds [runner arguments]");
    const outputDir = args[2];
    outputDir.mkdirRecurse;
    auto samples = File(outputDir ~ "/samples.jsonl", "a");
    foreach (round; 0 .. args[5].to!uint)
    foreach (offset; 0 .. 2)
    {
        const selected = (round + offset) % 2;
        const variant = selected ? "selected" : "baseline";
        const stem = outputDir ~ "/" ~ variant ~ "-" ~ round.to!string;
        const r = execute(["taskset", "-c", environment.get("BUILD_STUDY_CPU", "4"), args[3 + selected]] ~ args[6 .. $]
            ~ ["--bench-json=" ~ stem ~ ".json"]);
        (stem ~ ".run.log").write(r.output);
        JSONValue sample;
        sample["variant"] = variant;
        sample["round"] = round;
        sample["runExit"] = r.status;
        if (!r.status)
        {
            auto report = parseJSON((stem ~ ".json").readText);
            const error = benchmarkError(report);
            if (error.length)
            {
                sample["runExit"] = 1;
                sample["validationError"] = error;
            }
        }
        samples.writeln(sample.toString);
        samples.flush;
        writeln(sample.toString);
        assert(sample["runExit"].integer == 0, r.output ~ "\n" ~ sample.toString);
    }
    return 0;
}

private int checkDebugInfo(string outputDir) @system
{
    outputDir.mkdirRecurse;
    const source = outputDir ~ "/line_table_probe.d";
    const binary = outputDir ~ "/line_table_probe";
    source.write("module line_table_probe;\nimport std.stdio : writeln;\n"
        ~ "pragma(inline, false) void leaf() @safe { throw new Exception(\"probe\"); }\n"
        ~ "pragma(inline, false) void caller() @safe { leaf(); }\n"
        ~ "void main() @system { try caller(); catch (Exception e) { writeln(e); } }\n");
    auto build = execute(["ldc2", "-g", "--gline-tables-only", "-L--export-dynamic",
        source, "-of=" ~ binary]);
    assert(build.status == 0, build.output);
    auto run = execute([binary]);
    (outputDir ~ "/stack-trace.txt").write(run.output);
    assert(run.status == 0 && run.output.canFind("line_table_probe.d:4")
        && run.output.canFind("line_table_probe.caller"), run.output);
    writeln(run.output);
    return 0;
}

version (unittest) {} else
int main(string[] args) @system
{
    if (args.length > 1 && args[1] == "--compare") return compare(args);
    if (args.length > 1 && args[1] == "--compare-graph") return compareGraph(args);
    if (args.length == 3 && args[1] == "--check-debug-info") return checkDebugInfo(args[2]);
    assert(args.length >= 5, "capture output-dir compile|link|bench rounds [runtime-args...]");
    const commands = commandsFrom(args[1].readText);
    const outputDir = args[2];
    const mode = args[3];
    assert(["compile", "link", "bench"].canFind(mode));
    outputDir.mkdirRecurse;
    string[] variants = mode == "compile"
        ? ["baseline", "no-linkonce", "singleobj", "no-allinst", "no-debug-info", "line-tables"]
        : mode == "link" ? ["gold-shared", "bfd-shared", "lld-shared", "mold-shared", "wild-shared",
            "gold-static", "bfd-static", "lld-static", "mold-static", "wild-static"]
        : ["baseline", "static", "nobounds", "generic-cpu", "O2", "thin-lto", "assertions", "no-linkonce"];
    const selected = environment.get("BUILD_STUDY_VARIANTS", "");
    if (selected.length) variants = selected.split(",");
    auto results = File(outputDir ~ "/samples.jsonl", "a");
    foreach (round; 0 .. args[4].to!uint)
    foreach (offset; 0 .. variants.length)
    {
        const variant = variants[(offset + round) % variants.length];
        auto cc = commands.compile.dup;
        auto ld = commands.link.dup;
        const object = outputDir ~ "/" ~ variant ~ ".o";
        const binary = outputDir ~ "/" ~ variant;
        foreach (ref t; cc) if (t.startsWith("-of")) t = "-of" ~ object;
        foreach (ref t; ld)
        {
            if (t.startsWith("-of")) t = "-of" ~ binary;
            else if (t == commands.object) t = mode == "link" ? commands.object : object;
        }
        if (mode == "compile")
        {
            if (variant == "no-linkonce") cc = cc.filter!(t => !t.canFind("linkonce-templates")).array;
            if (variant == "singleobj") cc ~= "-singleobj";
            if (variant == "no-allinst") cc = cc.filter!(t => t != "-allinst").array;
            if (variant == "no-debug-info") cc = cc.filter!(t => t != "-g").array;
            if (variant == "line-tables") { cc = cc.filter!(t => t != "-g").array; cc ~= "--gline-tables-only"; }
        }
        else if (mode == "link")
        {
            ld = ld.filter!(t => !t.canFind("linker=") && !t.canFind("link-defaultlib-shared")).array;
            const parts = variant.split("-");
            ld ~= parts[0] == "wild" ? "-Xcc=-B" ~ environment.get("BUILD_STUDY_WILD_DIR",
                "/tmp/opencode/wild-linker") : "--linker=" ~ parts[0];
            ld ~= "--link-defaultlib-shared=" ~ (parts[1] == "shared" ? "true" : "false");
            if (parts.length > 2) ld ~= "-L--threads=" ~ parts[2][1 .. $];
        }
        else
        {
            if (variant == "static")
            {
                ld = ld.filter!(t => !t.canFind("link-defaultlib-shared")).array;
                ld ~= "--link-defaultlib-shared=false";
            }
            if (variant == "nobounds") cc ~= "--boundscheck=off";
            if (variant == "assertions") cc = cc.filter!(t => t != "-release").array;
            if (variant == "no-linkonce") cc = cc.filter!(t => !t.canFind("linkonce-templates")).array;
            if (variant == "generic-cpu") cc = cc.filter!(t => !t.startsWith("-mcpu=")).array;
            if (variant == "O2") { cc = cc.filter!(t => t != "-O3").array; cc ~= "-O2"; }
            if (variant == "thin-lto")
            {
                cc ~= "--flto=thin";
                ld = ld.filter!(t => !t.canFind("linker=")).array;
                ld ~= ["--flto=thin", "--linker=lld"];
            }
        }
        JSONValue record;
        record["variant"] = variant;
        record["round"] = round;
        foreach (phase; mode == "link" ? ["link"] : ["compile", "link"])
        {
            const command = (phase == "compile" ? cc : ld).join(" ");
            (outputDir ~ "/" ~ variant ~ "." ~ phase ~ ".command").write(command ~ "\n");
            auto timer = StopWatch();
            timer.start;
            auto r = executeShell(command);
            timer.stop;
            record[phase ~ "Ms"] = timer.peek.total!"msecs";
            record[phase ~ "Exit"] = r.status;
            (outputDir ~ "/" ~ variant ~ "." ~ phase ~ ".log").write(r.output);
            if (r.status) break;
        }
        if (mode == "bench" && record.object.get("linkExit", JSONValue(-1)).integer == 0)
        {
            auto r = execute(["taskset", "-c", environment.get("BUILD_STUDY_CPU", "4"), binary] ~ args[5 .. $]
                ~ ["--bench-json=" ~ outputDir ~ "/" ~ variant ~ "-" ~ round.to!string ~ ".json"]);
            record["runExit"] = r.status;
            (outputDir ~ "/" ~ variant ~ "-" ~ round.to!string ~ ".run.log").write(r.output);
            if (!r.status)
            {
                const error = benchmarkError(parseJSON((outputDir ~ "/" ~ variant
                    ~ "-" ~ round.to!string ~ ".json").readText));
                if (error.length)
                {
                    record["runExit"] = 1;
                    record["validationError"] = error;
                }
            }
        }
        if (binary.exists)
        {
            record["binaryBytes"] = binary.getSize;
            (outputDir ~ "/" ~ variant ~ ".identity.log").write(execute(["readelf", "-p", ".comment", binary]).output);
            (outputDir ~ "/" ~ variant ~ ".ldd.log").write(execute(["ldd", binary]).output);
        }
        if (object.exists) record["objectBytes"] = object.getSize;
        results.writeln(record.toString);
        results.flush;
        writeln(record.toString);
    }
    return 0;
}
