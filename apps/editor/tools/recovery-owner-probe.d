#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-recovery-owner-probe"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "sparkles:event-horizon-sys" path="../../.."
    dependency "sparkles:test-utils" path="../../.."
    dflags "-preview=in" "-preview=dip1000" "-I$PACKAGE_DIR/../src"
    dflags "-i=document_files" "-i=session_record" "-i=session_archive" "-i=session_directory"
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
import sparkles.test_utils.tmpfs : TmpFS;
import session_archive : appendSessionGeneration, readSessionGeneration;
import session_directory : DirectoryIssueKind, SessionDirectory;
import session_record : SessionRecord, SessionSelection, SessionTab;

int main(string[] args) @system
{
    if (args.length == 1)
    {
        auto fixture = TmpFS.create();
        const source = fixture.writeFile("disk bytes");
        auto owner = pipeProcess([thisExePath, "owner", fixture.dir, source],
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
        writeln("active lease refused; killed owner reclaimed; durable dirty text recovered");
        return 0;
    }
    if (args[1] == "owner")
    {
        assert(args.length == 4);
        auto directory = SessionDirectory.create(args[2], args[2]);
        assert(directory.hasValue);
        scope (exit) directory.value.close();
        SessionRecord record;
        record.generation = 1;
        record.active = 7;
        record.tabs = [SessionTab(id: 7, name: "draft", path: args[3], content: "unsaved text",
            savedContent: "disk bytes", selections: [SessionSelection(0, 0)])];
        const written = appendSessionGeneration(directory.value.path, record);
        assert(written.hasValue && written.value.durable);
        writeln(directory.value.path);
        stdout.flush();
        readln(); // Parent holds this pipe open until killing this task-owned process.
        return 0;
    }
    assert(args[1] == "claim" && args.length == 3);
    auto directory = SessionDirectory.claim(args[2]);
    if (directory.hasError)
    {
        if (directory.error.kind == DirectoryIssueKind.busy) return 3;
        stderr.writeln(directory.error.message);
        return 2;
    }
    scope (exit) directory.value.close();
    const recovered = readSessionGeneration(directory.value.path, 1);
    assert(recovered.hasValue && recovered.value.tabs[0].content == "unsaved text");
    return 0;
}
