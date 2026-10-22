#!/usr/bin/env dub
/+ dub.sdl:
    name "compare_app_builds"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Serial, checkpointed before/after test-build comparison for every root app.
module compare_app_builds;

import std.algorithm : any, sort;
import std.array : array;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONOptions, JSONValue, parseJSON;
import std.format : format;
import std.path : absolutePath, buildPath;
import std.process : Config, execute;
import std.regex : matchAll;
import std.stdio : writeln;
import std.string : lineSplitter;

private double median(double[] values) @safe
{
    assert(values.length);
    values.sort;
    const middle = values.length / 2;
    return values.length % 2 ? values[middle] : (values[middle - 1] + values[middle]) / 2;
}

/// Even sample counts average the central pair rather than choosing one.
@("appBuildStudy.median.evenAndOdd")
@safe unittest
{
    assert(median([3.0, 1.0, 2.0]) == 2);
    assert(median([4.0, 1.0, 2.0, 3.0]) == 2.5);
}

private int summarize(string output, string evidencePath = null) @system
{
    JSONValue[] evidence;
    writeln("| App | Root compile (s), before → after | Dependencies (s), before → after | Link (s), before → after | Total (s), before → after | Reduction |");
    writeln("| --- | ---: | ---: | ---: | ---: | ---: |");
    foreach (app; parseJSON(buildPath(output, "outcomes.json").readText)["apps"].array)
    {
        assert(app["replayExit"].integer == 0, app.toString);
        double[][string] samples;
        foreach (line; buildPath(output, app["app"].str, app["graphDirectory"].str, "samples.jsonl").readText.lineSplitter)
        {
            auto row = parseJSON(line);
            row["app"] = app["app"];
            evidence ~= row;
            assert(row["compileExit"].integer == 0 && row["linkExit"].integer == 0);
            const v = row["variant"].str;
            const root = row["rootCompileMs"].integer;
            const compile = row["compileMs"].integer;
            const link = row["linkMs"].integer;
            samples[v ~ ".root"] ~= root / 1000.0;
            samples[v ~ ".deps"] ~= (compile - root) / 1000.0;
            samples[v ~ ".link"] ~= link / 1000.0;
            samples[v ~ ".total"] ~= (compile + link) / 1000.0;
        }
        string result = "| " ~ app["app"].str ~ " |";
        foreach (metric; ["root", "deps", "link", "total"])
        {
            assert(samples["baseline." ~ metric].length == 3 && samples["selected." ~ metric].length == 3);
            result ~= format(" %.3f → %.3f |", median(samples["baseline." ~ metric]), median(samples["selected." ~ metric]));
        }
        const reduction = 100 * (1 - median(samples["selected.total"]) / median(samples["baseline.total"]));
        writeln(result, format(" %.1f%% |", reduction));
    }
    if (evidencePath.length)
    {
        JSONValue document;
        document["baselineCommit"] = "f71a5bffe";
        document["selectedCommit"] = "2f6d74c26";
        document["protocol"] = "Three alternating forced test-build graph replays per app and configuration; warm filesystem; excludes DUB setup and suite execution. Predates the wrapped-lld default.";
        document["samples"] = evidence;
        evidencePath.write(document.toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n");
    }
    return 0;
}

private string[] applications(string manifest) @safe
{
    string[] result;
    foreach (m; manifest.matchAll(`(?m)^subPackage "apps/([^"/]+)"`)) result ~= m[1];
    return result.sort.array;
}

/// Nested fixture packages are not apps in the root package catalog.
@("appBuildStudy.applications.rootEntries")
@safe unittest
{
    assert(applications("subPackage \"apps/hue\"\nsubPackage \"libs/base\"\n"
        ~ "subPackage \"apps/ci\"\n") == ["ci", "hue"]);
}

version (unittest) {} else
int main(string[] args) @system
{
    if ((args.length == 3 || args.length == 4) && args[1] == "--summarize")
        return summarize(args[2], args.length == 4 ? args[3] : null);
    assert(args.length == 6, "baseline-root selected-root benchmark-driver output-root rounds");
    const roots = [args[1].absolutePath, args[2].absolutePath];
    const driver = args[3].absolutePath;
    const output = args[4].absolutePath;
    const apps = applications(buildPath(roots[0], "dub.sdl").readText);
    assert(apps == applications(buildPath(roots[1], "dub.sdl").readText));
    output.mkdirRecurse;
    JSONValue[] outcomes;
    foreach (app; apps)
    {
        const dir = buildPath(output, app);
        dir.mkdirRecurse;
        const checkpoint = buildPath(dir, "outcome.json");
        if (checkpoint.exists)
        {
            outcomes ~= parseJSON(checkpoint.readText);
            writeln("Already recorded: ", app);
            continue;
        }
        JSONValue outcome;
        outcome["app"] = app;
        bool ready = true;
        foreach (variant; 0 .. 2)
        {
            const label = variant ? "selected" : "baseline";
            writeln("Capturing ", app, " / ", label);
            auto r = execute(["dub", "test", ":" ~ app, "--force", "--verbose", "--", "--help"],
                null, Config.none, size_t.max, roots[variant]);
            buildPath(dir, label ~ ".capture.txt").write(r.output);
            outcome[label ~ "CaptureExit"] = r.status;
            if (r.status)
            {
                ready = false;
                writeln("Capture failed: ", app, " / ", label, "; see capture log");
            }
        }
        if (ready)
        {
            string graphDir = "graph";
            uint attempt;
            while (buildPath(dir, graphDir).exists)
                graphDir = "graph-" ~ (++attempt).to!string;
            outcome["graphDirectory"] = graphDir;
            writeln("Measuring ", app, " (", args[5], " paired graph rounds)");
            auto r = execute([driver, "--compare-graph", buildPath(dir, "baseline.capture.txt"),
                buildPath(dir, "selected.capture.txt"), buildPath(dir, graphDir), args[5], roots[0], roots[1]],
                null, Config.none, size_t.max, roots[1]);
            buildPath(dir, "replay.log").write(r.output);
            outcome["replayExit"] = r.status;
            writeln("Replay exit: ", app, " = ", r.status);
        }
        checkpoint.write(outcome.toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n");
        outcomes ~= outcome;
        JSONValue summary;
        summary["apps"] = outcomes;
        summary["rounds"] = args[5].to!uint;
        buildPath(output, "outcomes.json").write(summary.toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n");
    }
    return outcomes.any!(o => o.object.get("replayExit", JSONValue(-1)).integer != 0) ? 1 : 0;
}
