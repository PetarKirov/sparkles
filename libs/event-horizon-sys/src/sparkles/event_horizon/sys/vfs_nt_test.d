/**
Native tests of the Windows `BlockingVfs` (testing.md oracles 1, 3, 4 and 6).

Trees are built with Win32 calls in a fresh temporary directory, never through
the backend under test. Symbolic links need a privilege or developer mode; a
row whose links cannot be made, as under Wine, is skipped and counted rather
than passed.
*/
module sparkles.event_horizon.sys.vfs_nt_test;

version (unittest):
version (Windows):

import std.conv : to;
import std.file : exists, getAttributes, isFile, mkdirRecurse, read, rmdirRecurse, tempDir, write;
import std.path : buildPath, dirName;
import std.string : indexOf;
import std.utf : toUTF16z;

import core.sys.windows.windows;

import sparkles.base.vfs;
import sparkles.base.vfs.testing : runAttackTable;
import sparkles.event_horizon.sys.vfs_nt;

extern (Windows) BOOLEAN CreateSymbolicLinkW(LPCWSTR, LPCWSTR, DWORD) nothrow @nogc;
enum DWORD SYMBOLIC_LINK_FLAG_DIRECTORY = 1, SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 2;

string scratchDir(string tag) @safe
{
    import std.random : uniform;

    auto dir = buildPath(tempDir, "vfs-" ~ tag ~ "-" ~ uniform(0, uint.max).to!string);
    mkdirRecurse(dir);
    return dir;
}

/// Whether the tests run under Wine rather than Windows.
bool underWine() @trusted
    => GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version") !is null;

/// Creates a link that the file system really resolves; false otherwise.
bool makeLink(string link, string target) @trusted
{
    const full = buildPath(dirName(link), target);
    const directory = !(exists(full) && isFile(full));
    if (!CreateSymbolicLinkW(link.toUTF16z, target.toUTF16z,
            (directory ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0) | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))
        return false;
    // Wine reports success for links it cannot open afterwards.
    const attrs = GetFileAttributesW(link.toUTF16z);
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT);
}

/// The Windows `BlockingVfs` fixture for the attack table.
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
                return false;
        mkdirRecurse(buildPath(top, "outside"));
        write(buildPath(top, "outside", "secret"), "secret");
        mkdirRecurse(buildPath(top, "r"));
        foreach (e; tree)
        {
            const spec = e[2 .. $];
            if (e[0] == 'd')
                mkdirRecurse(buildPath(top, "r", spec));
            else if (e[0] == 'f')
            {
                mkdirRecurse(dirName(buildPath(top, "r", spec)));
                write(buildPath(top, "r", spec), "");
            }
        }
        // Links last, so each target's kind is known.
        foreach (e; tree)
            if (e[0] == 'l')
            {
                const spec = e[2 .. $];
                const gt = spec.indexOf('>');
                const link = buildPath(top, "r", spec[0 .. gt]);
                mkdirRecurse(dirName(link));
                if (!makeLink(link, spec[gt + 1 .. $]))
                    return false;
            }
        return true;
    }

    bool isAt(BlockingVfs.Handle h, string path) @trusted
    {
        BY_HANDLE_FILE_INFORMATION got, want;
        if (!GetFileInformationByHandle(cast(HANDLE)*cast(size_t*)&h, &got))
            return false;
        auto e = CreateFileW(buildPath(top, path).toUTF16z, FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS, null);
        if (e == INVALID_HANDLE_VALUE)
            return false;
        scope (exit) CloseHandle(e);
        GetFileInformationByHandle(e, &want);
        return got.dwVolumeSerialNumber == want.dwVolumeSerialNumber
            && got.nFileIndexHigh == want.nFileIndexHigh && got.nFileIndexLow == want.nFileIndexLow;
    }

    bool exists(string path) @trusted
        => GetFileAttributesW(buildPath(top, path).toUTF16z) != INVALID_FILE_ATTRIBUTES;

    const(ubyte)[] contents(string path) @safe => cast(const(ubyte)[]) read(buildPath(top, path));

    /// Whether this process can create links: a privilege or developer mode on
    /// Windows, and not under Wine.
    bool canSymlink() @safe
    {
        const probe = buildPath(top, "link-probe");
        mkdirRecurse(buildPath(top, "link-target"));
        return makeLink(probe, "link-target");
    }

    string linkTarget(string path) @safe
    {
        auto v = new BlockingVfs;
        auto root = openRoot!(Rights.all)(v, dirName(buildPath(top, path)), ambientAuthority());
        char[4096] buf;
        import std.path : baseName;

        auto r = root.value.readlinkAt(baseName(path), buf[]);
        return r.hasError ? "" : r.value.idup;
    }
}

private void expectNoFailures(string[] failures, string what) @safe
{
    if (failures.length)
    {
        import std.array : join;

        assert(0, what ~ ":\n" ~ failures.join("\n"));
    }
}

@("vfs.nt.oracle1.defaultResolver")
@safe unittest
{
    size_t skipped;
    auto failures = runAttackTable!NativeFixture(() => NativeFixture.make(), skipped);
    expectNoFailures(failures, "attack table, default resolver");
}

@("vfs.nt.oracle3.componentWalk")
@safe unittest
{
    size_t skipped;
    auto failures = runAttackTable!NativeFixture(() => NativeFixture.make(), skipped,
        (BlockingVfs* v) { v.forceComponentWalk = true; });
    expectNoFailures(failures, "attack table, component walk");
}


@("vfs.nt.oracle4.differential")
@safe unittest
{
    static string run(R)(ref R root)
    {
        string log;
        void ok(string what, bool failed, ErrorKind k) { log ~= what ~ "=" ~ (failed ? k.to!string : "ok") ~ ";"; }
        auto a = root.walkAll("a/b");
        ok("walkAll", a.hasError, a.hasError ? a.error.kind : ErrorKind.other);
        auto w = a.value.writeFileAtomic("f", "content");
        ok("write", w.hasError, w.hasError ? w.error.kind : ErrorKind.other);
        auto again = root.mkdirAt("a");
        ok("mkdirExisting", again.hasError, again.hasError ? again.error.kind : ErrorKind.other);
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

    auto mem = new MemVfs(new MemNode[256], new ubyte[1 << 16]);
    mem.mkdirs("r");
    auto memRoot = openRoot!(Rights.all)(mem, "r", ambientAuthority());
    const memLog = run(memRoot.value);

    auto dir = scratchDir("diff");
    auto v = new BlockingVfs;
    auto nativeRoot = openRoot!(Rights.all)(v, dir, ambientAuthority());
    auto nativeLog = run(nativeRoot.value);
    // Wine's POSIX-semantics deletion removes a non-empty directory; Windows
    // refuses it with STATUS_DIRECTORY_NOT_EMPTY.
    if (underWine)
    {
        import std.array : replace;

        nativeLog = nativeLog.replace("rmdirNonEmpty=ok", "rmdirNonEmpty=notEmpty");
    }
    assert(memLog == nativeLog, "\nMemVfs:      " ~ memLog ~ "\nBlockingVfs: " ~ nativeLog);
}

@("vfs.nt.VFN2.classification")
@safe unittest
{
    auto dir = scratchDir("classify");
    write(buildPath(dir, "f"), "x");
    auto v = new BlockingVfs;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
    assert(root.value.openDir("f").error.kind == ErrorKind.notADirectory);
    assert(root.value.openDir("missing").error.kind == ErrorKind.notFound);
    assert(!root.value.mkdirAt("d").hasError);
    assert(root.value.mkdirAt("d").error.kind == ErrorKind.exists);
    assert(root.value.unlinkAt("d").error.kind == ErrorKind.isADirectory);
    assert(root.value.openFile!(OpenMode.read)("d").error.kind == ErrorKind.isADirectory);
    assert(root.value.rmdirAt("f").error.kind == ErrorKind.notADirectory);
    assert(root.value.statAt("d").value.kind == EntryKind.directory);
    assert(root.value.statAt("f").value.size == 1);
}

@("vfs.nt.VFH8.notInheritable")
@system unittest
{
    auto dir = scratchDir("inherit");
    auto v = new BlockingVfs;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
    auto sub = root.value.walk("");
    foreach (h; [root.value.backendHandle, sub.value.backendHandle])
    {
        DWORD flags;
        assert(GetHandleInformation(cast(HANDLE)*cast(size_t*)&h, &flags));
        assert(!(flags & HANDLE_FLAG_INHERIT));
    }
}

@("vfs.nt.VFN12.ownerOnlyAccessControl")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (underWine)
        skipTest("Wine does not keep a protected DACL; the Windows leg checks it");
    auto dir = scratchDir("acl");
    auto v = new BlockingVfs;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
    assert(!root.value.openFile!(OpenMode.createNew)("own", OwnerOnly()).hasError);
    assert(!root.value.openFile!(OpenMode.createNew)("shared", Shared()).hasError);

    size_t aces(string name, out bool isProtected)
    {
        ubyte[4096] sd;
        DWORD got;
        if (!GetFileSecurityW(buildPath(dir, name).toUTF16z, DACL_SECURITY_INFORMATION,
                cast(PSECURITY_DESCRIPTOR) sd.ptr, sd.length, &got))
            return size_t.max;
        BOOL present, defaulted;
        ACL* dacl;
        GetSecurityDescriptorDacl(cast(PSECURITY_DESCRIPTOR) sd.ptr, &present, &dacl, &defaulted);
        SECURITY_DESCRIPTOR_CONTROL control;
        DWORD revision;
        GetSecurityDescriptorControl(cast(PSECURITY_DESCRIPTOR) sd.ptr, &control, &revision);
        isProtected = (control & SE_DACL_PROTECTED) != 0;
        return present && dacl ? dacl.AceCount : 0;
    }

    bool ownProtected, sharedProtected;
    const own = aces("own", ownProtected);
    aces("shared", sharedProtected);
    assert(ownProtected, "an owner-only entry's DACL is protected from inheritance");
    assert(own >= 1, "the owner is granted access");
    assert(!sharedProtected, "a shared entry inherits its parent's access control");
}

@("vfs.nt.VFN13.readOnlyRemoval")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (underWine)
        skipTest("Wine maps read-only onto Unix permissions and refuses even attribute access");
    auto dir = scratchDir("readonly");
    mkdirRecurse(buildPath(dir, "t", "objects"));
    write(buildPath(dir, "t", "objects", "pack"), "x");
    SetFileAttributesW(buildPath(dir, "t", "objects", "pack").toUTF16z, FILE_ATTRIBUTE_READONLY);
    auto v = new BlockingVfs;
    auto root = openRoot!(Rights.all)(v, dir, ambientAuthority());
    auto r = root.value.removeTree("t");
    assert(!r.hasError, "removeTree: " ~ (r.hasError ? r.error.kind.to!string ~ " op " ~ r.error.op.to!string ~ " 0x"
        ~ (cast(uint) r.error.code).to!string(16) : ""));
    assert(!exists(buildPath(dir, "t")));
}
