#!/usr/bin/env dub
/+ dub.sdl:
    name "check_sync_litmus"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Oracle 9 of `docs/specs/base/sync/testing.md`: base.sync's litmus tests,
optimized.

`dub test` builds them unoptimized, and there the weakened variants of the
locks show no stale read on arm64 — neither on Apple cores nor on Neoverse.
The orderings a weakened primitive drops become visible once the compiler may
move the protected accesses across its relaxed atomics, so the oracle runs an
`-O3` build: `litmus_test.d` with `-unittest` and `SparklesSyncLitmus`, the
primitives without, so only the litmus tests run. On arm64 every weakened
variant must show a stale read within its budget; everywhere, the real
primitives must show none.

    dub run --single --temp-build libs/base/tools/check-sync-litmus.d
*/
module check_sync_litmus;

import std.algorithm : canFind, filter, map;
import std.array : array;
import std.file : dirEntries, mkdirRecurse, SpanMode, tempDir;
import std.path : buildPath;
import std.process : execute, kill, spawnProcess, tryWait, wait;
import std.stdio : stderr, writeln;

import core.thread : Thread;
import core.time : minutes, MonoTime, msecs;

/// The whole run's budget; it takes about a minute on the reference machines.
enum timeLimit = 10.minutes;

int main()
{
    enum sync = "libs/base/src/sparkles/base/sync";
    const dir = buildPath(tempDir, "sparkles-sync-litmus");
    mkdirRecurse(dir);
    const sources = dirEntries(sync, "*.d", SpanMode.shallow)
        .map!(e => e.name)
        .filter!(n => !n.canFind("_test.d") && !n.canFind("model.d") && !n.canFind("package.d"))
        .array;
    const flags = ["-O3", "-preview=in", "-preview=dip1000", "-Ilibs/base/src"];
    const objects = buildPath(dir, "primitives.o");
    const lib = execute(["ldc2", "-c", "-singleobj", "-of=" ~ objects] ~ flags ~ sources);
    if (lib.status != 0)
    {
        writeln(lib.output);
        return 1;
    }
    const bin = buildPath(dir, "litmus");
    const b = execute(["ldc2", "-unittest", "-main", "-d-version=SparklesSyncLitmus",
        "-of=" ~ bin] ~ flags ~ [sync ~ "/litmus_test.d", objects]);
    if (b.status != 0)
    {
        writeln(b.output);
        return 1;
    }
    // A weakened primitive may lose a wake-up and never finish; that is a
    // failure of the run, not a pass, so it gets a time limit.
    auto pid = spawnProcess([bin]);
    const deadline = MonoTime.currTime + timeLimit;
    for (;;)
    {
        const w = tryWait(pid);
        if (w.terminated)
            return w.status;
        if (MonoTime.currTime > deadline)
        {
            kill(pid);
            wait(pid);
            stderr.writeln("check-sync-litmus: no result within ", timeLimit, ": a litmus run hung");
            return 1;
        }
        Thread.sleep(100.msecs);
    }
}
