/**
Native tests of `BlockingVfs` (testing.md oracles 1, 3, 4 and 6).

Trees are built with plain POSIX calls in a fresh temporary directory, never
through the backend under test. The attack table runs twice: once with the
platform's kernel resolver where it applies, once forced onto the component
walk (oracle 3); both answer to the same hand-derived expectations, so they
agree with each other.
*/
module sparkles.event_horizon.sys.vfs_test;

version (unittest):
version (Posix):

import std.conv : to;
import std.file : exists, mkdirRecurse, read, readLink, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath, dirName;
import std.string : indexOf, toStringz;

import sparkles.base.vfs;
import sparkles.base.vfs.testing : runAttackTable;
import sparkles.event_horizon.sys.vfs;

/// A fresh directory under the system temp dir, removed by `cleanup`.
string scratchDir(string tag) @safe
{
    import std.random : uniform;

    auto dir = buildPath(tempDir, "vfs-" ~ tag ~ "-" ~ uniform(0, uint.max).to!string);
    mkdirRecurse(dir);
    return dir;
}

/// The `BlockingVfs` fixture for the attack table.
struct NativeFixture
{
    alias Backend = BlockingVfs;
    BlockingVfs* backend;
    string top;

    static NativeFixture make() @safe => NativeFixture(new BlockingVfs, scratchDir("attack"));

    BlockingVfs* vfs() @safe => backend;
    string rootPath() @safe => buildPath(top, "r");

    bool build(in string[] tree) @safe
    {
        foreach (e; tree)
            if (e[0] == 'm')
                return false; // mounts need privileges; the mount test covers them
        mkdirRecurse(buildPath(top, "outside"));
        write(buildPath(top, "outside", "secret"), "secret");
        mkdirRecurse(buildPath(top, "r"));
        foreach (e; tree)
        {
            const spec = e[2 .. $];
            final switch (e[0])
            {
                case 'd': mkdirRecurse(buildPath(top, "r", spec)); break;
                case 'f':
                    mkdirRecurse(dirName(buildPath(top, "r", spec)));
                    write(buildPath(top, "r", spec), "");
                    break;
                case 'l':
                    const gt = spec.indexOf('>');
                    const link = buildPath(top, "r", spec[0 .. gt]);
                    mkdirRecurse(dirName(link));
                    symlink(spec[gt + 1 .. $], link);
                    break;
                case 'm': assert(0);
            }
        }
        return true;
    }

    bool isAt(BlockingVfs.Handle h, string path) @safe
    {
        import core.sys.posix.sys.stat : stat, stat_t;

        auto st = backend.fstat(h, StatMask.basic);
        stat_t want;
        if (st.hasError || (() @trusted => stat(buildPath(top, path).toStringz, &want))() != 0)
            return false;
        // Device alone is not identity; compare the inode through a second fstat.
        return st.value.device == want.st_dev && inodeOf(h) == want.st_ino;
    }

    ulong inodeOf(BlockingVfs.Handle h) @trusted
    {
        import core.sys.posix.sys.stat : fstat, stat_t;

        stat_t st;
        fstat(*cast(int*)&h, &st);
        return st.st_ino;
    }

    bool exists(string path) @safe
    {
        import core.sys.posix.sys.stat : lstat, stat_t;

        stat_t st;
        return (() @trusted => lstat(buildPath(top, path).toStringz, &st))() == 0;
    }

    const(ubyte)[] contents(string path) @safe => cast(const(ubyte)[]) read(buildPath(top, path));
    string linkTarget(string path) @safe => readLink(buildPath(top, path));
}

private void expectNoFailures(string[] failures, string what) @safe
{
    if (failures.length)
    {
        import std.array : join;

        assert(0, what ~ ":\n" ~ failures.join("\n"));
    }
}

@("vfs.blocking.oracle1.defaultResolver")
@safe unittest
{
    size_t skipped;
    auto failures = runAttackTable!NativeFixture(() => NativeFixture.make(), skipped);
    expectNoFailures(failures, "attack table, default resolver");
    assert(skipped == 2 * 8, "only the two mount rows are skipped");
}

@("vfs.blocking.oracle3.componentWalk")
@safe unittest
{
    // The same rows forced onto the component walk: with oracle 1 above, both
    // resolvers meet the same expectations, so they agree (VFR1).
    size_t skipped;
    auto failures = runAttackTable!NativeFixture(() => NativeFixture.make(), skipped,
        (BlockingVfs* v) { v.forceComponentWalk = true; });
    expectNoFailures(failures, "attack table, component walk");
}

@("vfs.blocking.VFR2.reportsTheKernelResolver")
@safe unittest
{
    auto v = new BlockingVfs;
    auto dir = scratchDir("vfr2");
    ResolvePolicy strict, macCovered;
    macCovered.crossMounts = true;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority(), strict);
    auto crossing = openRoot!(Rights.all)(v, dir, ambientAuthority(), macCovered);
    version (linux)
    {
        assert(root.value.resolution == Resolution.kernelWholePath);
        assert(root.value.mountCheck == MountCheck.kernel);
    }
    else version (OSX)
    {
        assert(root.value.resolution == Resolution.componentWalk, "O_NOFOLLOW_ANY needs crossMounts");
        assert(crossing.value.resolution == Resolution.kernelWholePath);
        assert(root.value.mountCheck == MountCheck.racy);
    }
    rmdirRecurse(dir);
}

@("vfs.blocking.VFP8.realMountPoint")
@safe unittest
{
    // A mount point every system has: /proc on Linux, /dev on macOS.
    version (linux)
        enum mounted = "proc";
    else version (OSX)
        enum mounted = "dev";
    else
        enum mounted = "";
    static if (mounted.length)
    {
        auto v = new BlockingVfs;
        ResolvePolicy refuse, allow;
        allow.crossMounts = true;
        foreach (force; [false, true])
        {
            v.forceComponentWalk = force;
            auto strict = openRoot!(Rights.readOnly)(v, "/", ambientAuthority(), refuse);
            assert(strict.value.walk(mounted).error.kind == ErrorKind.crossesMount);
            auto open = openRoot!(Rights.readOnly)(v, "/", ambientAuthority(), allow);
            assert(!open.value.walk(mounted).hasError);
        }
    }
}

@("vfs.blocking.VFN14.searchOnlyDirectory")
@system unittest
{
    import core.sys.posix.sys.stat : chmod;

    auto dir = scratchDir("search");
    mkdirRecurse(buildPath(dir, "s", "c"));
    chmod(buildPath(dir, "s").toStringz, octal111);
    scope (exit)
    {
        chmod(buildPath(dir, "s").toStringz, octal755);
        rmdirRecurse(dir);
    }
    auto v = new BlockingVfs;
    foreach (force; [false, true])
    {
        v.forceComponentWalk = force;
        auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
        auto c = root.value.walk("s/c");
        assert(!c.hasError, "walk through a search-only directory, forced walk: " ~ force.to!string
            ~ ": " ~ (c.hasError ? c.error.kind.to!string : ""));
    }
}

private enum uint octal111 = 73, octal755 = 493, octal777 = 511, octal666 = 438,
    octal600 = 384, octal700 = 448;

@("vfs.blocking.VFN12.sharingModeBits")
@system unittest
{
    import core.sys.posix.sys.stat : umask;

    const mask = umask(octal777 & ~octal755); // read the umask...
    umask(mask);                              // ...and put it back
    auto dir = scratchDir("sharing");
    scope (exit) rmdirRecurse(dir);
    auto v = new BlockingVfs;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
    assert(!root.value.mkdirAt("shared").hasError);
    assert(!root.value.mkdirAt("own", OwnerOnly()).hasError);
    assert(!root.value.openFile!(OpenMode.createNew)("f", OwnerOnly()).hasError);
    assert(!root.value.mkdirAt("bits", PosixMode(octal700 | 8)).hasError);
    assert(root.value.statAt("shared").value.permissions == (octal777 & ~mask));
    assert(root.value.statAt("own").value.permissions == (octal700 & ~mask));
    assert(root.value.statAt("f").value.permissions == (octal600 & ~mask));
    assert(root.value.statAt("bits").value.permissions == ((octal700 | 8) & ~mask));
}

@("vfs.blocking.VFH8.closeOnExec")
@system unittest
{
    import core.sys.posix.fcntl : fcntl, F_GETFD, FD_CLOEXEC;

    auto dir = scratchDir("cloexec");
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "f"), "x");
    auto v = new BlockingVfs;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
    auto file = root.value.openFile!(OpenMode.read)("f");
    auto sub = root.value.walk("");
    foreach (h; [root.value.backendHandle, sub.value.backendHandle])
    {
        const fd = *cast(const(int)*)&h;
        assert(fcntl(fd, F_GETFD) & FD_CLOEXEC);
    }
}

@("vfs.blocking.VFN2.classification")
@safe unittest
{
    auto dir = scratchDir("classify");
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "f"), "x");
    symlink("f", buildPath(dir, "l"));
    auto v = new BlockingVfs;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
    assert(root.value.openDir("f").error.kind == ErrorKind.notADirectory);
    assert(root.value.openDir("l").error.kind == ErrorKind.symlinkRefused);
    assert(root.value.openFile!(OpenMode.read)("l").error.kind == ErrorKind.symlinkRefused);
    assert(root.value.statAt("l").value.kind == EntryKind.symlink);
    assert(root.value.unlinkAt("missing").error.kind == ErrorKind.notFound);
    assert(!root.value.mkdirAt("d").hasError);
    assert(root.value.unlinkAt("d").error.kind == ErrorKind.isADirectory);
    assert(root.value.openFile!(OpenMode.read)("d").error.kind == ErrorKind.isADirectory);
}

@("vfs.blocking.VFR5.withdrawal")
@safe unittest
{
    version (linux) {} else version (OSX) {} else return;
    auto dir = scratchDir("withdraw");
    scope (exit) rmdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "a"));
    auto v = new BlockingVfs;
    ResolvePolicy p;
    version (OSX)
        p.crossMounts = true;
    auto required = openRoot!(Rights.all)(v, dir, ambientAuthority(), p, CreateDefault.shared_, true);
    auto ordinary = openRoot!(Rights.all)(v, dir, ambientAuthority(), p);
    assert(ordinary.value.resolution == Resolution.kernelWholePath);
    v.simulateWithdrawal = true;
    assert(ordinary.value.resolution == Resolution.componentWalk, "the change is reported");
    assert(!ordinary.value.walk("a").hasError, "an ordinary root uses the component walk");
    assert(required.value.walk("a").error.kind == ErrorKind.unsupported,
        "a root that requires the kernel resolver fails");
}

@("vfs.blocking.oracle4.differential")
@safe unittest
{
    // One scenario on both backends; the trees and every result must match.
    static string run(R)(ref R root)
    {
        string log;
        void note(string what, ErrorKind k) { log ~= what ~ "=" ~ k.to!string ~ ";"; }
        void ok(string what, bool failed, ErrorKind k) { log ~= what ~ "=" ~ (failed ? k.to!string : "ok") ~ ";"; }
        auto a = root.walkAll("a/b");
        ok("walkAll", a.hasError, a.hasError ? a.error.kind : ErrorKind.other);
        auto w = a.value.writeFileAtomic("f", "content");
        ok("write", w.hasError, w.hasError ? w.error.kind : ErrorKind.other);
        auto again = root.mkdirAt("a");
        ok("mkdirExisting", again.hasError, again.hasError ? again.error.kind : ErrorKind.other);
        auto link = root.symlinkAt("l", "a");
        ok("symlink", link.hasError, link.hasError ? link.error.kind : ErrorKind.other);
        auto viaLink = root.walk("l/b");
        ok("walkThroughLink", viaLink.hasError, viaLink.hasError ? viaLink.error.kind : ErrorKind.other);
        auto ren = a.value.renameAt("f", a.value, "g");
        ok("rename", ren.hasError, ren.hasError ? ren.error.kind : ErrorKind.other);
        auto st = a.value.statAt("g");
        log ~= "size=" ~ (st.hasError ? "x" : st.value.size.to!string) ~ ";";
        auto rd = root.rmdirAt("a");
        ok("rmdirNonEmpty", rd.hasError, rd.hasError ? rd.error.kind : ErrorKind.other);
        auto rt = root.removeTree("a");
        ok("removeTree", rt.hasError, rt.hasError ? rt.error.kind : ErrorKind.other);
        auto l = root.list();
        string entries;
        while (l.value.next().value)
            entries ~= l.value.front.name.idup ~ ",";
        log ~= "entries=" ~ entries;
        return log;
    }

    auto mem = testVfsForOtherPackages();
    mem.mkdirs("r");
    auto memRoot = openRoot!(Rights.all)(mem, "r", ambientAuthority());
    const memLog = run(memRoot.value);

    auto dir = scratchDir("diff");
    scope (exit) rmdirRecurse(dir);
    auto v = new BlockingVfs;
    auto nativeRoot = openRoot!(Rights.all)(v, dir, ambientAuthority());
    const nativeLog = run(nativeRoot.value);
    assert(memLog == nativeLog, "\nMemVfs:      " ~ memLog ~ "\nBlockingVfs: " ~ nativeLog);
}

// MemVfs over GC arenas; `testVfs` is package-private to sparkles.base.vfs.
MemVfs* testVfsForOtherPackages() @safe => new MemVfs(new MemNode[256], new ubyte[1 << 16]);
