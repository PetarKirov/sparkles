#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-storage-fault-probe"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "sparkles:event-horizon-sys" path="../../.."
    dependency "sparkles:text-buffer" path="../../.."
    dependency "sparkles:test-utils" path="../../.."
    dflags "-preview=in" "-preview=dip1000" "-I$PACKAGE_DIR/../src" "-i=document_files"
    dflags "-i=session_record" "-i=session_archive" "-i=session_directory"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// A child process for strace syscall-fault injection; asserts forbidden destination writes.
module storage_fault_probe;

import std.file : exists, readText;
import std.path : buildPath;
import std.stdio : writeln;
import sparkles.test_utils.tmpfs : TmpFS;
import document_files : saveAtomic, SaveAuthorization;
import session_archive : appendSessionGeneration, readSessionGeneration;
import session_record : SessionRecord, SessionSelection, SessionTab;
import std.algorithm.searching : startsWith;

private void recoveryFault(string mode, ref TmpFS fixture) @system
{
    const source = fixture.writeFile("original bytes");
    SessionRecord record;
    record.generation = 1;
    record.active = 7;
    record.tabs = [SessionTab(id: 7, name: "draft", path: source, content: "old unsaved",
        savedContent: "original bytes", selections: [SessionSelection(0, 0)])];
    const first = appendSessionGeneration(fixture.dir, record);
    assert(first.hasValue && first.value.durable);
    record.generation = 2;
    record.tabs[0].content = "new unsaved";
    const second = appendSessionGeneration(fixture.dir, record);
    if (mode == "recovery-directory-sync-failure")
    {
        assert(second.hasValue && !second.value.durable && second.value.warning.length);
        const latest = readSessionGeneration(fixture.dir, 2);
        assert(latest.hasValue && latest.value.tabs[0].content == "new unsaved");
    }
    else
    {
        assert(mode == "recovery-precommit" && second.hasError);
        assert(readSessionGeneration(fixture.dir, 2).hasError);
    }
    const prior = readSessionGeneration(fixture.dir, 1);
    assert(prior.hasValue && prior.value.tabs[0].content == "old unsaved");
    assert(readText(source) == "original bytes");
}

int main(string[] args) @system
{
    assert(args.length == 2, "Pass a save or recovery fault mode.");
    const mode = args[1];
    auto fixture = TmpFS.create();
    if (mode.startsWith("recovery-"))
    {
        recoveryFault(mode, fixture);
        writeln(mode, ": verified");
        return 0;
    }
    const creating = mode == "create-failure";
    const path = creating ? buildPath(fixture.dir, "new.txt") : fixture.writeFile("original bytes");
    const result = saveAtomic(path, "replacement bytes", creating
        ? SaveAuthorization.createOnly : SaveAuthorization.replaceConfirmed);
    if (mode == "baseline")
    {
        assert(result.hasValue && result.value.durable);
        assert(readText(path) == "replacement bytes");
    }
    else if (mode == "directory-sync-failure")
    {
        assert(result.hasValue && !result.value.durable && result.value.warning.length);
        assert(readText(path) == "replacement bytes");
    }
    else
    {
        assert(mode == "precommit" || creating);
        assert(result.hasError, "The syscall fault did not reach the intended save stage.");
        if (creating) assert(!exists(path), "A failed atomic create wrote a destination.");
        else assert(readText(path) == "original bytes", "A failed save changed the destination.");
    }
    writeln(mode, ": verified");
    return 0;
}
