/**
Oracle 5 of `docs/specs/base/vfs/testing.md`: compile-fail rights.

One case per operation and missing right (VFH6), plus widening through
`attenuate` (VFH5), a borrow escaping its owner (VFH2), a handle of one
backend passed to another (VFH3), copying an owner (VFH1), and the sharing
rules (VFO5). Each negative case has a positive twin that differs only in
the right or argument under test, so a case fails for the intended reason
and not for a typo.
*/
module sparkles.base.vfs.oracle_rights;

version (unittest):

import sparkles.base.vfs;
import sparkles.base.vfs.mem : testVfs;

private:

alias D(Rights R) = Dir!(MemVfs, R);

// `op` applied to a handle with all rights but `missing` must not compile,
// and with all rights must.
enum string checkOp(string op, string missing) = `
    static assert(__traits(compiles, (ref D!(Rights.all) d) { ` ~ op ~ `; }),
        "positive control failed");
    static assert(!__traits(compiles,
        (ref D!(cast(Rights)(Rights.all & ~Rights.` ~ missing ~ `)) d) { ` ~ op ~ `; }),
        "compiled without ` ~ missing ~ `");
`;

@("vfs.oracle5.operationsNeedTheirRights")
@safe unittest
{
    mixin(checkOp!(`d.openDir("x")`, "lookup"));
    mixin(checkOp!(`d.openFile!(OpenMode.read)("x")`, "read"));
    mixin(checkOp!(`d.openFile!(OpenMode.write)("x")`, "write"));
    mixin(checkOp!(`d.openFile!(OpenMode.createNew)("x")`, "create"));
    mixin(checkOp!(`d.mkdirAt("x")`, "create"));
    mixin(checkOp!(`d.statAt("x")`, "stat"));
    mixin(checkOp!(`char[4] b; d.readlinkAt("x", b[])`, "stat"));
    mixin(checkOp!(`d.symlinkAt("x", "y")`, "create"));
    mixin(checkOp!(`d.unlinkAt("x")`, "remove"));
    mixin(checkOp!(`d.rmdirAt("x")`, "remove"));
    mixin(checkOp!(`d.renameAt("x", d, "y")`, "rename"));
    mixin(checkOp!(`d.list()`, "list"));
    mixin(checkOp!(`d.walk("x")`, "lookup"));
    mixin(checkOp!(`d.walkAll("x")`, "lookup"));
    mixin(checkOp!(`d.walkAll("x")`, "create"));
    mixin(checkOp!(`d.removeTree("x")`, "lookup"));
    mixin(checkOp!(`d.removeTree("x")`, "list"));
    mixin(checkOp!(`d.removeTree("x")`, "remove"));
    mixin(checkOp!(`d.writeFileAtomic("x", "y")`, "create"));
    mixin(checkOp!(`d.writeFileAtomic("x", "y")`, "write"));
    mixin(checkOp!(`d.writeFileAtomic("x", "y")`, "rename"));
}

@("vfs.oracle5.sharingNeedsCreateShared")
@safe unittest
{
    mixin(checkOp!(`d.mkdirAt("x", Shared())`, "createShared"));
    mixin(checkOp!(`d.openFile!(OpenMode.createNew)("x", Shared())`, "createShared"));
    mixin(checkOp!(`d.walkAll("x", Shared())`, "createShared"));
    mixin(checkOp!(`d.writeFileAtomic("x", "y", Shared())`, "createShared"));
    version (Posix)
    {
        mixin(checkOp!(`d.mkdirAt("x", PosixMode(448))`, "createShared"));
        // PosixMode already states the bits.
        enum OpenMode execNew = OpenMode(Access.write, Disposition.createNew, true);
        static assert(__traits(compiles,
            (ref D!(Rights.all) d) { d.openFile!execNew("x", OwnerOnly()); }));
        static assert(!__traits(compiles,
            (ref D!(Rights.all) d) { d.openFile!execNew("x", PosixMode(448)); }));
    }
    // OwnerOnly needs only create.
    static assert(__traits(compiles, (ref D!(cast(Rights)(Rights.all & ~Rights.createShared)) d) {
        d.mkdirAt("x", OwnerOnly());
    }));
    // A sharing argument needs a creating mode.
    static assert(!__traits(compiles, (ref D!(Rights.all) d) {
        d.openFile!(OpenMode.write)("x", OwnerOnly());
    }));
}

@("vfs.oracle5.attenuationNeverWidens")
@safe unittest
{
    static assert(__traits(compiles,
        (ref D!(Rights.all) d) { auto r = d.attenuate!(Rights.readOnly); }));
    static assert(!__traits(compiles,
        (ref D!(Rights.readOnly) d) { auto r = d.attenuate!(Rights.all); }));
    // A borrow cannot widen either.
    static assert(!__traits(compiles, (ref D!(Rights.all) d) {
        auto r = d.attenuate!(Rights.readOnly);
        auto w = r.attenuate!(Rights.all);
    }));
}

@("vfs.oracle5.borrowsCannotEscape")
@safe unittest
{
    // VFH2, the case spike S3 established: a borrow of a local cannot leave.
    static assert(__traits(compiles, () @safe {
        D!(Rights.all) d;
        auto r = d.borrow();
        return r.alive;
    }));
    static assert(!__traits(compiles, () @safe {
        D!(Rights.all) d;
        return d.borrow();
    }));
    static assert(!__traits(compiles, () @safe {
        D!(Rights.all) d;
        return d.attenuate!(Rights.readOnly);
    }));
}

@("vfs.oracle5.ownersAreMoveOnly")
@safe unittest
{
    static assert(!__traits(compiles, (ref D!(Rights.all) a) { D!(Rights.all) b = a; }));
    static assert(!__traits(compiles,
        (ref File!(MemVfs, Rights.read) a) { File!(MemVfs, Rights.read) b = a; }));
}

// A second backend type over the same implementation, for VFH3.
struct OtherVfs
{
    MemVfs inner;
    alias Handle = MemVfs.Handle;
    alias Listing = MemVfs.Listing;
    alias inner this;
    @disable this(this);
}

@("vfs.oracle5.backendIsPartOfTheType")
@safe unittest
{
    static assert(isVfs!OtherVfs);
    static assert(__traits(compiles, (ref D!(Rights.all) a, ref D!(Rights.all) b) {
        a.renameAt("x", b, "y");
    }));
    static assert(!__traits(compiles,
        (ref D!(Rights.all) a, ref Dir!(OtherVfs, Rights.all) b) { a.renameAt("x", b, "y"); }));
}

@("vfs.oracle5.emptyHandlesFail")
@safe unittest
{
    // An owner cannot be made non-default-constructible (expected 0.4 needs
    // a default value), so an empty `.init` handle fails every operation.
    D!(Rights.all) d;
    assert(!d.alive);
    assert(d.openDir("x").error.context == "empty handle");
    assert(d.walk("x").error.context == "empty handle");
    assert(d.removeTree("x").error.context == "empty handle");
    assert(!d.close().hasError);
    File!(MemVfs, Rights.read) f;
    ubyte[1] b;
    assert(f.read(b[]).error.context == "empty handle");
    DirRef!(MemVfs, Rights.all) r;
    assert(!r.alive && r.statAt("x").error.context == "empty handle");
}
