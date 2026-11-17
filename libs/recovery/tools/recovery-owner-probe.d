#!/usr/bin/env dub
/+ dub.sdl:
    name "recovery-owner-probe"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:recovery" path="../../.."
    dependency "sparkles:test-utils" path="../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Kill a task-owned process after its durable checkpoint and reclaim its archive.
module recovery_owner_probe;

import core.sys.posix.signal : SIGKILL;
import std.file : readText, thisExePath;
import std.process : execute, kill, pipeProcess, Redirect, tryWait, wait;
import std.stdio : readln, stderr, stdout, writeln;
import std.string : strip;
import sparkles.recovery.archive : appendGeneration, readGeneration;
import sparkles.recovery.directory : DirectoryIssueKind, LeasedDirectory;
import sparkles.test_utils.tmpfs : TmpFS;

int main(string[] args) @system
{
    if (args.length == 1)
    {
        auto fixture = TmpFS.create();
        const source = fixture.writeFile("disk bytes");
        auto owner = pipeProcess([thisExePath, "owner", fixture.dir],
            Redirect.stdin | Redirect.stdout);
        scope (exit)
        {
            if (!tryWait(owner.pid).terminated) kill(owner.pid, SIGKILL);
            wait(owner.pid);
        }
        const path = owner.stdout.readln().strip;
        assert(path.length, "Owner exited before acknowledging its checkpoint.");
        const busy = execute([thisExePath, "claim", path]);
        assert(busy.status == 3, busy.output);
        kill(owner.pid, SIGKILL);
        wait(owner.pid);
        const reclaimed = execute([thisExePath, "claim", path]);
        assert(reclaimed.status == 0, reclaimed.output);
        assert(readText(source) == "disk bytes");
        writeln("active lease refused; killed owner reclaimed; durable payload recovered");
        return 0;
    }
    if (args[1] == "owner")
    {
        assert(args.length == 3);
        auto directory = LeasedDirectory.create(args[2], args[2]);
        assert(directory.hasValue);
        scope (exit) directory.value.close();
        const written = appendGeneration(directory.value.path, 1, "unsaved text");
        assert(written.hasValue && written.value.durable);
        writeln(directory.value.path);
        stdout.flush();
        readln(); // Parent holds this pipe open until killing this task-owned process.
        return 0;
    }
    assert(args[1] == "claim" && args.length == 3);
    auto directory = LeasedDirectory.claim(args[2]);
    if (directory.hasError)
    {
        if (directory.error.kind == DirectoryIssueKind.busy) return 3;
        stderr.writeln(directory.error.message);
        return 2;
    }
    scope (exit) directory.value.close();
    assert(readGeneration(directory.value.path, 1).value == "unsaved text");
    return 0;
}
