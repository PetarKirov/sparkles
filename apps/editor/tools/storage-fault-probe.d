#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-storage-fault-probe"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:event-horizon-sys" path="../../.."
    dependency "sparkles:test-utils" path="../../.."
    dflags "-preview=in" "-preview=dip1000" "-I$PACKAGE_DIR/../src" "-i=document_files"
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

int main(string[] args) @system
{
    assert(args.length == 2, "Pass baseline, precommit, create-failure, or directory-sync-failure.");
    const mode = args[1];
    auto fixture = TmpFS.create();
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
