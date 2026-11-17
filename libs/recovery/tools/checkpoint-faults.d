#!/usr/bin/env dub
/+ dub.sdl:
    name "recovery-checkpoint-faults"
    targetPath "../../../build"
    dependency "sparkles:test-utils" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Inject a real directory fsync failure in the checkpoint writer's CPU thread.
module checkpoint_faults;

import sparkles.test_utils.tmpfs : TmpFS;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.file : exists, readText;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : indexOf, splitLines;

int main(string[] args) @system
{
    const probe = args.length > 1 ? args[1] : "build/recovery-checkpoint-fault-probe";
    enforce(exists(probe), "Build libs/recovery/tools/checkpoint-fault-probe.d first.");
    auto fixture = TmpFS.create();
    const tracePath = buildPath(fixture.dir, "checkpoint.trace");
    const result = execute(["strace", "-f", "-qq", "-yy", "-o", tracePath,
        "-e", "trace=fsync", "-e", "inject=fsync:error=EIO:when=8", probe, fixture.dir]);
    enforce(result.status == 0, result.output);
    bool directoryFailure;
    string[string] calls;
    const directoryToken = "<" ~ fixture.dir ~ ">";
    foreach (line; readText(tracePath).splitLines)
    {
        const separator = line.indexOf(' ');
        if (separator < 0) continue;
        string thread = line[0 .. separator];
        if (line.canFind("fsync(")) calls[thread] = line;
        // strace can split a call into unfinished/resumed lines across threads.
        if (line.canFind("INJECTED"))
            if (const started = thread in calls)
                directoryFailure |= (*started).canFind(directoryToken);
    }
    enforce(directoryFailure, "The failure did not reach the worker's directory sync.");
    writeln(result.output);
    return 0;
}
