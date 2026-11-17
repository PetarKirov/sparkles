#!/usr/bin/env dub
/+ dub.sdl:
    name "recovery-storage-fault-probe"
    targetPath "../../../build"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:event-horizon-sys" path="../../.."
    dependency "sparkles:recovery" path="../../.."
    dependency "sparkles:test-utils" path="../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// A child process for strace syscall-fault injection; asserts forbidden destination writes.
module storage_fault_probe;

import std.algorithm.searching : startsWith;
import std.file : exists, readText;
import std.path : baseName, buildPath, dirName;
import std.stdio : writeln;
import sparkles.base.vfs : AtomicDisposition, AtomicMode, AtomicReceipt, IoResult, Rights,
    ambientAuthority, openRoot;
import sparkles.event_horizon.sys.vfs : BlockingVfs;
import sparkles.recovery.archive : appendGeneration, readGeneration;
import sparkles.test_utils.tmpfs : TmpFS;

/// A document save as an editor makes one: create-only, or replacing with the old mode.
IoResult!AtomicReceipt save(string path, string bytes, bool creating) @system
{
    enum create = AtomicMode(AtomicDisposition.createNew, syncDirectory: true);
    enum replace = AtomicMode(AtomicDisposition.replace, keepPermissions: true, syncDirectory: true);
    auto dir = openRoot!(Rights.all)(new BlockingVfs, dirName(path), ambientAuthority());
    assert(!dir.hasError);
    return creating ? dir.value.writeFileAtomic!create(baseName(path), bytes)
        : dir.value.writeFileAtomic!replace(baseName(path), bytes);
}

private void recoveryFault(string mode, ref TmpFS fixture) @system
{
    const source = fixture.writeFile("original bytes");
    const first = appendGeneration(fixture.dir, 1, "old unsaved");
    assert(first.hasValue && first.value.durable);
    const second = appendGeneration(fixture.dir, 2, "new unsaved");
    if (mode == "recovery-directory-sync-failure")
    {
        assert(second.hasValue && !second.value.durable && second.value.warning.length);
        assert(readGeneration(fixture.dir, 2).value == "new unsaved");
    }
    else
    {
        assert(mode == "recovery-precommit" && second.hasError);
        assert(readGeneration(fixture.dir, 2).hasError);
    }
    assert(readGeneration(fixture.dir, 1).value == "old unsaved");
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
    const result = save(path, "replacement bytes", creating);
    if (mode == "baseline")
    {
        assert(!result.hasError && result.value.directorySynced);
        assert(readText(path) == "replacement bytes");
    }
    else if (mode == "directory-sync-failure")
    {
        assert(!result.hasError && !result.value.directorySynced);
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
