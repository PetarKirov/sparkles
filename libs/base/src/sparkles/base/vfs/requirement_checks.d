/**
The requirement checks of `docs/specs/base/vfs/testing.md` that oracles 1, 2
and 5 do not cover, on `MemVfs`. Each test names the requirement it checks.
*/
module sparkles.base.vfs.requirement_checks;

version (unittest):

import sparkles.base.vfs;
import sparkles.base.vfs.mem : testVfs;

private:

auto rootOf(Rights R = Rights.all)(MemVfs* v, string path = "r",
    ResolvePolicy policy = ResolvePolicy.init, CreateDefault create = CreateDefault.shared_)
{
    v.mkdirs(path);
    auto r = openRoot!R(v, path, ambientAuthority(), policy, create);
    assert(!r.hasError);
    return r;
}

@("vfs.check.VFH1.oneClosePerOpen")
@safe unittest
{
    auto v = testVfs();
    v.writeFile("r/a/f", cast(const(ubyte)[]) "x");
    {
        auto root = rootOf(v);
        auto a = root.value.openDir("a");
        auto f = a.value.openFile!(OpenMode.read)("f");
        auto w = root.value.walk("a");
        assert(!f.value.close().hasError);
        assert(!f.value.close().hasError); // a second close is a no-op
        assert(v.openHandles == 3);
    }
    assert(v.openHandles == 0, "every open is closed exactly once");
}

@("vfs.check.VFE2.kinds")
@safe pure nothrow @nogc unittest
{
    static foreach (k; ["notFound", "exists", "notADirectory", "isADirectory", "notEmpty",
            "permission", "busy", "invalidName", "escapesRoot", "dotDotRefused",
            "symlinkRefused", "symlinkLoop", "crossesMount", "nameTooLong", "bufferTooSmall",
            "depthExceeded", "raceRetryExhausted", "unsupported", "other"])
        static assert(__traits(hasMember, ErrorKind, k), k);
}

@("vfs.check.VFE4.VFO3.eachOperationSucceedsAndFails")
@safe unittest
{
    auto v = testVfs();
    v.writeFile("r/a/f", cast(const(ubyte)[]) "data");
    v.symlink("r/l", "a");
    auto root = rootOf(v);
    ref d = root.value;

    static void fails(R)(auto ref R r, ErrorKind kind, OpKind op, int line = __LINE__)
    {
        import std.conv : to;

        assert(r.hasError, "line " ~ line.to!string ~ ": expected a failure");
        assert(r.error.kind == kind, "line " ~ line.to!string ~ ": kind " ~ r.error.kind.to!string);
        assert(r.error.op == op, "line " ~ line.to!string ~ ": op " ~ r.error.op.to!string);
    }

    assert(!d.openDir("a").hasError);
    fails(d.openDir("missing"), ErrorKind.notFound, OpKind.openAt);
    assert(!d.walk("a").value.openFile!(OpenMode.read)("f").hasError);
    fails(d.openFile!(OpenMode.read)("missing"), ErrorKind.notFound, OpKind.openAt);
    assert(!d.mkdirAt("m").hasError);
    fails(d.mkdirAt("m"), ErrorKind.exists, OpKind.mkdirAt);
    assert(d.statAt("a").value.kind == EntryKind.directory);
    assert(d.statAt("l").value.kind == EntryKind.symlink); // VFO2
    fails(d.statAt("missing"), ErrorKind.notFound, OpKind.statAt);
    char[8] target;
    assert(d.readlinkAt("l", target[]).value == "a");
    fails(d.readlinkAt("l", target[0 .. 0]), ErrorKind.bufferTooSmall, OpKind.readlinkAt);
    assert(!d.symlinkAt("l2", "a").hasError);
    fails(d.symlinkAt("l2", "a"), ErrorKind.exists, OpKind.symlinkAt);
    assert(!d.unlinkAt("l2").hasError);
    fails(d.unlinkAt("a"), ErrorKind.isADirectory, OpKind.unlinkAt);
    assert(!d.rmdirAt("m").hasError);
    fails(d.rmdirAt("a"), ErrorKind.notEmpty, OpKind.rmdirAt);
    assert(!d.renameAt("l", d, "l3").hasError);
    fails(d.renameAt("missing", d, "x"), ErrorKind.notFound, OpKind.renameAt);
    assert(!d.list().hasError);
    assert(!d.walkAll("x/y").hasError);
    fails(d.walk("missing"), ErrorKind.notFound, OpKind.openAt);
    assert(!d.removeTree("x").hasError);
    assert(!d.writeFileAtomic("w", "data").hasError);
    fails(d.walk("a").value.writeFileAtomic("f/x", "data"), ErrorKind.invalidName, OpKind.openAt);
}

@("vfs.check.VFO4.openModes")
@safe unittest
{
    auto v = testVfs();
    auto root = rootOf(v);
    ref d = root.value;
    auto created = d.openFile!(OpenMode.createNew)("f");
    assert(!created.hasError);
    assert(created.value.write(cast(const(ubyte)[]) "abc").value == 3);
    assert(d.openFile!(OpenMode.createNew)("f").error.kind == ErrorKind.exists);
    auto appended = d.openFile!(OpenMode.append)("f");
    appended.value.write(cast(const(ubyte)[]) "d");
    assert(v.contents("r/f") == "abcd");
    auto truncated = d.openFile!(OpenMode.createOrTruncate)("f");
    assert(v.contents("r/f").length == 0);
    assert(d.openFile!(OpenMode.read)("g").error.kind == ErrorKind.notFound);
    auto rw = d.openFile!(OpenMode(Access.readWrite, Disposition.createNew, true))("x");
    assert(!rw.hasError && d.statAt("x").value.executable);
}

@("vfs.check.VFO5.sharing")
@safe unittest
{
    auto v = testVfs();
    auto root = rootOf(v);
    ref d = root.value;
    assert(!d.mkdirAt("shared").hasError);
    assert(v.sharingOf("r/shared").kind == Sharing.Kind.shared_);
    assert(!d.mkdirAt("own", OwnerOnly()).hasError);
    assert(v.sharingOf("r/own").kind == Sharing.Kind.ownerOnly);
    version (Posix)
    {
        assert(!d.mkdirAt("bits", PosixMode(488)).hasError);
        assert(v.sharingOf("r/bits") == Sharing(Sharing.Kind.posixMode, 488));
        assert(d.statAt("bits").value.permissions == 488);
        assert(d.statAt("own").value.permissions == 448);
    }

    // Without createShared, the default narrows to OwnerOnly.
    auto narrowed = d.attenuate!(cast(Rights)(Rights.all & ~Rights.createShared));
    assert(!narrowed.mkdirAt("floor").hasError);
    assert(v.sharingOf("r/floor").kind == Sharing.Kind.ownerOnly);

    // A root's default applies when no argument is given.
    auto v2 = testVfs();
    auto owned = rootOf(v2, "r", ResolvePolicy.init, CreateDefault.ownerOnly);
    assert(!owned.value.writeFileAtomic("f", "x").hasError);
    assert(v2.sharingOf("r/f").kind == Sharing.Kind.ownerOnly);
}

@("vfs.check.VFO6.stat")
@safe unittest
{
    auto v = testVfs();
    v.writeFile("r/f", cast(const(ubyte)[]) "hello", true);
    v.setMtime("r/f", 42);
    auto root = rootOf(v);
    auto basic = root.value.statAt("f").value;
    assert(basic.kind == EntryKind.regular && basic.size == 5 && basic.executable);
    assert(!basic.hasMtime);
    auto timed = root.value.statAt("f", StatMask.mtime).value;
    assert(timed.hasMtime && timed.mtimeNs == 42);
}

@("vfs.check.VFO7.listing")
@safe unittest
{
    auto v = testVfs();
    foreach (n; ["r/a", "r/b", "r/c"])
        v.writeFile(n, null);
    auto root = rootOf(v);
    auto l1 = root.value.list();
    auto l2 = root.value.list();
    size_t n1, n2;
    while (l1.value.next().value)
    {
        assert(l1.value.front.name.length == 1);
        ++n1;
        if (l2.value.next().value)
            ++n2;
    }
    while (l2.value.next().value)
        ++n2;
    assert(n1 == 3 && n2 == 3);
}

@("vfs.check.VFO8.renameStaysInOneRoot")
@safe unittest
{
    auto v = testVfs();
    v.writeFile("r/f", null);
    auto one = rootOf(v);
    auto two = rootOf(v);
    const before = v.totalCalls;
    auto moved = one.value.renameAt("f", two.value, "g");
    assert(moved.error.kind == ErrorKind.escapesRoot);
    assert(v.totalCalls == before, "refused before any backend call");
    assert(v.exists("r/f") && !v.exists("r/g"));
}

@("vfs.check.VFO9.temporaryRemovedOnFailure")
@safe unittest
{
    // A full arena fails the write after the temporary is created.
    auto v = testVfs(64, 64);
    auto root = rootOf(v);
    ubyte[128] big;
    auto w = root.value.writeFileAtomic("f", big[]);
    assert(w.hasError && w.error.context == "arena exhausted");
    auto l = root.value.list();
    assert(!l.value.next().value, "no temporary entry is left behind");
}

@("vfs.check.VFO10.linkTargets")
@safe unittest
{
    auto v = testVfs();
    auto root = rootOf(v);
    v.resetCounts();
    assert(root.value.symlinkAt("s", "").error.kind == ErrorKind.invalidName);
    assert(root.value.symlinkAt("s", "a\0b").error.kind == ErrorKind.invalidName);
    assert(root.value.symlinkAt("s", "/etc").error.kind == ErrorKind.escapesRoot);
    assert(v.totalCalls == 0);
}

@("vfs.check.VFP1.VFP2.policy")
@safe unittest
{
    ResolvePolicy p;
    assert(p.symlinks == SymlinkPolicy.none && p.dotDot == DotDotPolicy.reject && !p.crossMounts);

    auto v = testVfs();
    v.mkdirs("r/a");
    ResolvePolicy beneath;
    beneath.symlinks = SymlinkPolicy.beneath;
    auto root = rootOf(v, "r", beneath);
    assert(root.value.walk("a").value.policy == beneath);
    assert(root.value.openDir("a").value.policy == beneath);
}

@("vfs.check.VFR2.reportsItsResolver")
@safe unittest
{
    auto v = testVfs();
    auto refused = rootOf(v);
    assert(refused.value.resolution == Resolution.componentWalk);
    assert(refused.value.mountCheck == MountCheck.racy);
    ResolvePolicy crossing;
    crossing.crossMounts = true;
    auto allowed = rootOf(v, "r", crossing);
    assert(allowed.value.mountCheck == MountCheck.none);
    auto required = openRoot!(Rights.all)(v, "r", ambientAuthority(), ResolvePolicy.init,
        CreateDefault.shared_, true);
    assert(required.error.kind == ErrorKind.unsupported); // VFR3: MemVfs has no kernel resolver
}

// A backend whose kernel resolver refuses every lookup, for VFR4 and VFB3.
// Public: a private type's members are not visible to the concept check.
public:
struct RefusingKernel
{
    MemVfs inner;
    alias Handle = MemVfs.Handle;
    alias Listing = MemVfs.Listing;
    alias inner this;
    size_t wholePathCalls;
    @disable this(this);

    bool wholePathFor(ResolvePolicy) @safe nothrow @nogc
    {
        ++wholePathCalls;
        return true;
    }

    IoResult!Handle resolveWhole(Handle, scope const(char)[], ResolvePolicy) @safe nothrow @nogc
        => ioErr!Handle(ErrorKind.symlinkRefused, OpKind.resolve);
}

@("vfs.check.VFR4.VFB3.neverDowngrade")
@safe unittest
{
    static assert(isVfs!RefusingKernel);
    static assert(hasWholePathResolver!RefusingKernel);
    auto k = new RefusingKernel(MemVfs(new MemNode[64], new ubyte[1024]));
    k.mkdirs("r/a");
    auto root = openRoot!(Rights.all)(k, "r", ambientAuthority());
    assert(k.wholePathCalls == 1, "wholePathFor is asked once, at openRoot");
    assert(root.value.resolution == Resolution.kernelWholePath);
    k.resetCounts();
    auto d = root.value.walk("a");
    assert(d.error.kind == ErrorKind.symlinkRefused, "the kernel's refusal is the result");
    assert(k.count(OpKind.openAt) == 0 && k.count(OpKind.statAt) == 0,
        "no component primitive ran for the refused lookup");
    assert(k.wholePathCalls == 1);
}

@("vfs.check.VFD1.boundedStack")
@safe unittest
{
    auto v = testVfs(256);
    string path = "r/t";
    foreach (i; 0 .. maxRemovalDepth)
        path ~= "/d";
    v.mkdirs(path); // t plus 64 nested: one deeper than the limit
    v.writeFile("r/sentinel", cast(const(ubyte)[]) "keep");
    auto root = rootOf(v);
    auto r = root.value.removeTree("t");
    assert(r.error.kind == ErrorKind.depthExceeded);
    assert(v.contents("r/sentinel") == "keep");
    assert(v.openHandles == 1, "removal closed every handle it opened; only the root's remains");
}

@("vfs.check.VFD3.manyEntries")
@safe unittest
{
    auto v = testVfs(5100, 1);
    v.mkdirs("r/t");
    foreach (i; 0 .. 5000)
    {
        import std.conv : to;

        v.writeFile("r/t/f" ~ i.to!string, null);
    }
    auto root = rootOf(v);
    assert(!root.value.removeTree("t").hasError);
    assert(!v.exists("r/t"));
}

@("vfs.check.VFD5.VFP8.partialProgress")
@safe unittest
{
    // A mounted subtree stops the removal under crossMounts = false; what was
    // removed stays removed and nothing outside the named entry changes.
    auto v = testVfs();
    v.writeFile("r/t/a/f", null);
    v.mkdirs("r/t/m/x");
    v.mount("r/t/m");
    v.writeFile("r/sentinel", cast(const(ubyte)[]) "keep");
    auto root = rootOf(v);
    auto r = root.value.removeTree("t");
    assert(r.error.kind == ErrorKind.crossesMount);
    assert(v.exists("r/t/m/x"), "the mounted subtree is untouched");
    assert(v.contents("r/sentinel") == "keep");
}

@("vfs.check.allocation.gc")
@system unittest
{
    import core.memory : GC;

    auto nodes = new MemNode[128];
    auto bytes = new ubyte[4096];
    auto v = new MemVfs(nodes, bytes);
    v.writeFile("r/a/f", cast(const(ubyte)[]) "data");
    v.symlink("r/l", "a");

    static void exercise(MemVfs* v) @safe nothrow @nogc
    {
        ResolvePolicy beneath;
        beneath.symlinks = SymlinkPolicy.beneath;
        auto root = openRoot!(Rights.all)(v, "r", ambientAuthority(), beneath);
        auto d = root.value.walkAll("x/y");
        cast(void) d.value.writeFileAtomic("w", "payload");
        auto l = root.value.walk("l");
        auto listing = root.value.list();
        while (!listing.value.next().hasError && listing.value.next().value) {}
        cast(void) root.value.removeTree("x");
        cast(void) root.value.removeTree("a");
    }

    exercise(v); // warm up
    const before = GC.allocatedInCurrentThread();
    exercise(v);
    assert(GC.allocatedInCurrentThread() == before, "a VFS operation allocated on the GC heap");
}

// A backend that can open for search only, for VFN14.
struct SearchingVfs
{
    MemVfs inner;
    alias Handle = MemVfs.Handle;
    alias Listing = MemVfs.Listing;
    alias inner this;
    size_t searchOpens;
    @disable this(this);

    IoResult!Handle openSearchAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        ++searchOpens;
        return inner.openDirAt(dir, name);
    }
}

@("vfs.check.VFN14.walkOpensForSearch")
@safe unittest
{
    static assert(hasSearchOpen!SearchingVfs && !hasSearchOpen!MemVfs);
    auto v = new SearchingVfs(MemVfs(new MemNode[64], new ubyte[1024]));
    v.writeFile("r/a/b/c/f", null);
    auto root = openRoot!(Rights.all)(v, "r", ambientAuthority());
    v.resetCounts();
    auto c = root.value.walk("a/b/c");
    assert(!c.hasError);
    assert(v.searchOpens == 3, "every directory passed through is opened for search");
    // The double forwards each search open to openDirAt, so: three, plus the reopen.
    assert(v.count(OpKind.openAt) == 4, "only the result is reopened with full access");
    auto l = c.value.list();
    assert(l.value.next().value && l.value.front.name == "f");
    assert(v.openHandles == 3, "the root, the result, and the listing's own handle");
}
