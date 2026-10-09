/**
The native test kit for capability VFS backends over a real file system.

`BlockingVfs` and event-horizon's `RingVfs` run the same oracles
(`docs/specs/base/vfs/testing.md`): the attack table through
$(LREF NativeFixture), whose trees are built with plain POSIX calls rather
than through the backend under test, and the oracle-4 differential through
$(LREF differentialLog), whose transcript must be identical on every backend.
*/
module sparkles.event_horizon.sys.testing;

version (Posix):

import std.conv : to;
import std.file : mkdirRecurse, read, readLink, symlink, tempDir, write;
import std.path : buildPath, dirName;
import std.string : indexOf, toStringz;

import sparkles.base.vfs;

/// A fresh directory under the system temporary directory. The caller
/// removes it.
string scratchDir(string tag) @safe
{
    import std.random : uniform;

    auto dir = buildPath(tempDir, "vfs-" ~ tag ~ "-" ~ uniform(0, uint.max).to!string);
    mkdirRecurse(dir);
    return dir;
}

/// A `MemVfs` over GC arenas, for differential runs against a native backend.
MemVfs* differentialMemVfs() @safe => new MemVfs(new MemNode[256], new ubyte[1 << 16]);

/**
The attack-table fixture for a native backend `V` whose handles are POSIX
descriptors. Mount rows are skipped: they need privileges, and the backend's
own mount test covers them.
*/
struct NativeFixture(V)
{
    alias Backend = V;
    V* backend;
    string top;

    static NativeFixture make() @safe => NativeFixture(new V, scratchDir("attack"));

    V* vfs() @safe => backend;
    string rootPath() @safe => buildPath(top, "r");

    bool build(in string[] tree) @safe
    {
        foreach (e; tree)
            if (e[0] == 'm')
                return false;
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

    bool isAt(V.Handle h, string path) @safe
    {
        import core.sys.posix.sys.stat : stat, stat_t;

        stat_t want;
        if ((() @trusted => stat(buildPath(top, path).toStringz, &want))() != 0)
            return false;
        // Device alone is not identity; compare the inode as well.
        stat_t got;
        if (!fstatOf(h, got))
            return false;
        return got.st_dev == want.st_dev && got.st_ino == want.st_ino;
    }

    private static bool fstatOf(V.Handle h, out imported!"core.sys.posix.sys.stat".stat_t st)
        @trusted
    {
        import core.sys.posix.sys.stat : fstat;

        static assert(V.Handle.sizeof == int.sizeof, "the handle is a descriptor");
        return fstat(*cast(int*)&h, &st) == 0;
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

/**
Oracle 4's scenario: a fixed sequence of operations on `root`, recorded as a
transcript of outcomes and the final listing. Two backends agree when their
transcripts are equal.
*/
string differentialLog(R)(ref R root)
{
    string log;
    void ok(string what, bool failed, ErrorKind k)
    {
        log ~= what ~ "=" ~ (failed ? k.to!string : "ok") ~ ";";
    }

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
