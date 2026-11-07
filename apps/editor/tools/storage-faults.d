#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-storage-faults"
    targetPath "../../../build"
    dependency "sparkles:test-utils" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Linux black-box save failures against real native syscalls, not a duplicated storage model.
module storage_faults;

import std.algorithm.searching : canFind, startsWith;
import std.conv : text;
import std.exception : enforce;
import std.file : exists, readText;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : splitLines;
import sparkles.test_utils.tmpfs : TmpFS;

int main(string[] args) @system
{
    const probe = args.length > 1 ? args[1] : "build/editor-storage-fault-probe";
    enforce(exists(probe), "Build apps/editor/tools/storage-fault-probe.d first.");
    auto fixture = TmpFS.create();
    const baselinePath = buildPath(fixture.dir, "baseline.trace");
    const baseline = execute(["strace", "-qq", "-yy", "-o", baselinePath,
        "-e", "trace=close,fsync,write,renameat,linkat", probe, "baseline"]);
    enforce(baseline.status == 0, baseline.output);
    size_t ordinal, temporaryClose;
    foreach (line; readText(baselinePath).splitLines)
        if (line.startsWith("close("))
        {
            ++ordinal;
            if (line.canFind(".sparkles-editor-")) temporaryClose = ordinal;
        }
    enforce(temporaryClose != 0, "The baseline did not close a save temporary.");
    struct Case { string name, injection, mode; }
    Case[6] cases = [
        Case("write", "write:error=ENOSPC:when=2", "precommit"),
        Case("temporary-sync", "fsync:error=EIO:when=1", "precommit"),
        Case("temporary-close", text("close:error=EIO:when=", temporaryClose), "precommit"),
        Case("replacement", "renameat:error=EACCES:when=1", "precommit"),
        Case("atomic-create", "linkat:error=EEXIST:when=1", "create-failure"),
        Case("directory-sync", "fsync:error=EIO:when=2", "directory-sync-failure"),
    ];
    foreach (case_; cases)
    {
        const tracePath = buildPath(fixture.dir, case_.name ~ ".trace");
        const result = execute(["strace", "-qq", "-yy", "-o", tracePath,
            "-e", "inject=" ~ case_.injection, probe, case_.mode]);
        enforce(result.status == 0, case_.name ~ ": " ~ result.output);
        const trace = readText(tracePath);
        enforce(trace.canFind("INJECTED"), case_.name ~ ": no syscall fault was injected");
        if (case_.name == "temporary-close")
        {
            bool reached;
            foreach (line; trace.splitLines)
                reached |= line.startsWith("close(") && line.canFind(".sparkles-editor-")
                    && line.canFind("INJECTED");
            enforce(reached, "The close fault missed the save temporary.");
        }
        writeln(case_.name, ": verified");
    }
    return 0;
}
