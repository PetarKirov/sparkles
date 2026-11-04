#!/usr/bin/env dub
/+ dub.sdl:
    name "build_systems_rebuild_behavior"
    platforms "posix"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Runs the experiments documented in ../behavioral-evidence.md against the
 * installed GNU Make and Ninja. Assertions check executions and artifact bytes;
 * these experiments do not benchmark either engine.
 */
module rebuild_behavior;

import core.sys.posix.unistd : getpid;
import std.algorithm : canFind;
import std.array : replace;
import std.conv : to;
import std.datetime : Clock, dur;
import std.file : exists, mkdir, readText, remove, rmdirRecurse, setTimes, tempDir, thisExePath, timeLastModified, write;
import std.path : buildPath;
import std.process : Config, execute;
import std.stdio : File, writeln;
import std.string : splitLines, strip;

private string quoted(string value) @safe pure
    => "'" ~ value.replace("'", "'\\''") ~ "'";

private void worker(string[] args) @system
{
    auto log = File("executions", "a");
    log.writeln(args[2]);
    if (args[2] == "consume")
        write("final", "compiled:" ~ readText("generated"));
    else
    {
        const input = exists("optional") ? "optional" : "source";
        const content = readText(input).splitLines[0] ~ "\n";
        if (!exists("generated") || readText("generated") != content)
            write("generated", content);
    }
}

private string manifest(string engine, string revision) @system
{
    const command = thisExePath.quoted ~ " worker ";
    if (engine == "make")
        return "final: generated\n\t" ~ command ~ "consume\n"
            ~ "generated: source\n\t" ~ command ~ "generate-" ~ revision ~ "\n";
    return "rule generate\n  command = " ~ command ~ "generate-" ~ revision
        ~ "\n  restat = 1\nrule consume\n  command = " ~ command
        ~ "consume\nbuild generated: generate source\nbuild final: consume generated\n";
}

private void build(string engine, string directory) @system
{
    const result = engine == "make"
        ? execute(["make", "--no-print-directory", "-j1", "-f", "build.make", "final"], null,
            Config.none, size_t.max, directory)
        : execute(["ninja", "-j1", "-f", "build.ninja", "final"], null,
            Config.none, size_t.max, directory);
    assert(result.status == 0, result.output);
}

private void check(string engine, string directory, string scenario,
    string expectedLog, string expectedContent, string expectedFresh) @system
{
    write(buildPath(directory, "executions"), "");
    build(engine, directory);
    const actual = readText(buildPath(directory, "executions"));
    assert(actual == expectedLog, engine ~ " " ~ scenario ~ ": expected "
        ~ expectedLog ~ "; observed " ~ actual);
    assert(readText(buildPath(directory, "final")) == expectedContent,
        engine ~ " " ~ scenario ~ ": unexpected final bytes");
    const fresh = directory ~ "-fresh";
    mkdir(fresh);
    write(buildPath(fresh, "source"), readText(buildPath(directory, "source")));
    if (exists(buildPath(directory, "optional")))
        write(buildPath(fresh, "optional"), readText(buildPath(directory, "optional")));
    foreach (action; ["generate-v1", "consume"])
    {
        const result = execute([thisExePath, "worker", action], null, Config.none, size_t.max, fresh);
        assert(result.status == 0, result.output);
    }
    assert(readText(buildPath(fresh, "final")) == expectedFresh,
        engine ~ " " ~ scenario ~ ": unexpected fresh bytes");
    writeln(engine, " | ", scenario, " | ", actual.length ? actual.strip.replace("\n", ", ") : "none",
        " | retained=", expectedContent.strip, " | fresh=", expectedFresh.strip);
}

private void baseline(string engine, string directory) @system
{
    mkdir(directory);
    write(buildPath(directory, "source"), "alpha\n");
    const stamp = Clock.currTime - dur!"seconds"(30);
    setTimes(buildPath(directory, "source"), stamp, stamp);
    write(buildPath(directory, engine == "make" ? "build.make" : "build.ninja"), manifest(engine, "v1"));
    build(engine, directory);
}

private void experiments(string engine, string root) @system
{
    foreach (scenario; ["no-op", "unchanged-generated-output", "preserved-mtime", "missing-output", "changed-command", "untracked-negative-dependency"])
    {
        const directory = buildPath(root, engine ~ "-" ~ scenario);
        baseline(engine, directory);
        const source = buildPath(directory, "source");
        if (scenario == "unchanged-generated-output")
        {
            write(source, "alpha\nignored comment\n");
            const stamp = Clock.currTime + dur!"seconds"(1);
            setTimes(source, stamp, stamp);
        }
        else if (scenario == "preserved-mtime")
        {
            const stamp = timeLastModified(source);
            write(source, "beta\n");
            setTimes(source, stamp, stamp);
        }
        else if (scenario == "missing-output")
            remove(buildPath(directory, "generated"));
        else if (scenario == "untracked-negative-dependency")
            write(buildPath(directory, "optional"), "beta\n");
        else if (scenario == "changed-command")
            write(buildPath(directory, engine == "make" ? "build.make" : "build.ninja"), manifest(engine, "v2"));

        const expected = scenario == "unchanged-generated-output" ? "generate-v1\n"
            : scenario == "missing-output" ? "generate-v1\nconsume\n"
            : scenario == "changed-command" && engine == "ninja" ? "generate-v2\n"
            : "";
        const expectedFresh = scenario == "preserved-mtime" || scenario == "untracked-negative-dependency"
            ? "compiled:beta\n" : "compiled:alpha\n";
        check(engine, directory, scenario, expected, "compiled:alpha\n", expectedFresh);
    }
}

int main(string[] args) @system
{
    if (args.length > 1 && args[1] == "worker")
    {
        worker(args);
        return 0;
    }
    string[] available;
    foreach (engine; ["make", "ninja"])
    {
        try
        {
            const result = execute([engine, "--version"]);
            if (result.status == 0 && (engine != "make" || result.output.canFind("GNU Make")))
            {
                available ~= engine;
                writeln(engine, " version: ", result.output.splitLines[0]);
            }
            else
                writeln("SKIP: ", engine, " is unavailable or is not GNU Make");
        }
        catch (Exception error)
            writeln("SKIP: ", engine, ": ", error.msg);
    }
    const root = buildPath(tempDir, "sparkles-build-behavior-" ~ to!string(getpid()));
    mkdir(root);
    scope (exit) rmdirRecurse(root);
    foreach (engine; available)
        experiments(engine, root);
    return 0;
}
