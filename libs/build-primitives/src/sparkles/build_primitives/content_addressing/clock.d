/**
The file system's clock: the stamp a run of a digest cache records, read
from the file system that stamps the files (BGK5, FSC3).

A cache trusts a recorded digest only when the file's times lie safely
before the run's stamp. The process clock and a file system's timestamps
can disagree, a network file system's most of all, and a check that
compares the two misses the edits it exists to catch. So the stamp is the
modification time of a probe file just written beside the files, as git
takes its index file's. Where no probe can be written, a caller caches no
digest there.
*/
module sparkles.build_primitives.content_addressing.clock;

import sparkles.base.io.errors : IoResult, ioErr;
import sparkles.base.expected : ok;
import sparkles.base.text.errors : NoGcHook;

/// The name `fileSystemNow` writes by default.
enum defaultProbe = ".sparkles-clock-probe";

/**
The current time on the file system holding `dir`: the modification time of
`probe` once written there, replaced atomically (VFO9). `dir` is a VFS
directory handle with the rights to create, write, rename and stat. Fails
when the probe cannot be written or its time read.
*/
IoResult!long fileSystemNow(D)(ref D dir, scope const(char)[] probe = defaultProbe)
{
    import sparkles.base.io.errors : IoError;
    import sparkles.base.vfs.types : StatMask;

    auto written = dir.writeFileAtomic(probe, cast(const(ubyte)[]) null);
    if (written.hasError)
        return ioErr!long(written.error);
    auto st = dir.statAt(probe, StatMask.mtime);
    if (st.hasError)
        return ioErr!long(st.error);
    return ok!(IoError, NoGcHook)(st.value.mtimeNs);
}

/// The stamp is the file system's time, not the process's: an in-memory
/// backend stamps files with a clock of its own, and the probe reads it.
@("content_addressing.clock.fileSystemNow")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Rights;
    import sparkles.build_primitives.fileset.tree_literal : memTree;

    auto made = memTree("a = 1\n");
    assert(!made.hasError);
    auto vfs = &made.value.get().vfs;
    vfs.clockNs = 42_000_000_000;
    auto root = openRoot!(Rights.all)(vfs, "", ambientAuthority());
    assert(!root.hasError);
    auto now = fileSystemNow(root.value);
    assert(!now.hasError && now.value == 42_000_000_000);
    vfs.clockNs += 5;
    assert(fileSystemNow(root.value).value == 42_000_000_005, "a second probe reads the clock again");

    auto readOnly = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    static assert(!__traits(compiles, fileSystemNow(readOnly.value)), "a probe needs the rights to write");
}
