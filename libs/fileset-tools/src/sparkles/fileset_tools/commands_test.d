/**
The copy command and its verification (`XC`, `XV`, docs/specs/fsx), over
trees written with plain file calls in a fresh temporary directory.
*/
module sparkles.fileset_tools.commands_test;

version (unittest):
version (Posix):

import std.algorithm.searching : canFind, startsWith;
import std.conv : octal, text;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, setAttributes, symlink, tempDir, write;
import std.path : buildPath, dirName;

import sparkles.fileset_tools.commands : copyCommand, CopyOptions, VerifyMode;
import sparkles.fileset_tools.copy : CopyVfs;
import sparkles.fileset_tools.evaluate : evaluate, Root;
import sparkles.fileset_tools.verify : castoreText, digestMembers;

// A tree of files, an executable file, a nested directory and a link,
// beneath `<tmp>/fst-<pid>-<label>/src`.
private struct Fixture
{
    string top, src;

    static Fixture make(string label)
    {
        import std.process : thisProcessID;

        Fixture f;
        f.top = buildPath(tempDir, text("fst-", thisProcessID, "-", label));
        if (exists(f.top))
            rmdirRecurse(f.top);
        f.src = buildPath(f.top, "src");
        mkdirRecurse(buildPath(f.src, "a", "b"));
        write(buildPath(f.src, "top.txt"), "top");
        write(buildPath(f.src, "a", "one.d"), "module one;");
        write(buildPath(f.src, "a", "b", "run"), "#!/bin/sh\n");
        setAttributes(buildPath(f.src, "a", "b", "run"), octal!755);
        symlink("a/one.d", buildPath(f.src, "link"));
        return f;
    }

    string dest(string name) => buildPath(top, name);

    void remove() => rmdirRecurse(top);
}

private CopyOptions options(ref Fixture f, string dest)
{
    CopyOptions o;
    o.source = Root(dir: f.src);
    o.dest = dest;
    return o;
}

/// XV1: the castore id assembled from the members' records is the one the
/// fileset machine computes over the tree (its oracle, `CAC1`, `CAC2`).
@("fileset_tools.verify.castoreOfIsTheMachines")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Rights;
    import sparkles.event_horizon.sys : BlockingVfs;

    auto f = Fixture.make("castore");
    scope (exit) f.remove();
    const o = evaluate(Root(dir: f.src), "all()", withIds: true);
    string[] paths;
    foreach (ref m; o.found.members)
        paths ~= m.path;
    auto vfs = new BlockingVfs;
    auto root = openRoot!(Rights.readOnly)(vfs, f.src, ambientAuthority());
    string why;
    const records = digestMembers(root.value.borrow, paths, why);
    assert(!why.length, why);
    assert(castoreText(records) == o.castore, castoreText(records) ~ " " ~ o.castore);
}

/// XV1, XV2: a copy over each backend, hashed either way, is verified.
@("fileset_tools.commands.XV1.verified")
@system unittest
{
    auto f = Fixture.make("verified");
    scope (exit) f.remove();
    foreach (vfs; [CopyVfs.blocking, CopyVfs.ring])
        foreach (mode; [VerifyMode.separate, VerifyMode.inline])
        {
            auto o = options(f, f.dest(text("out-", vfs, "-", mode)));
            o.vfs = vfs;
            o.verify = mode;
            string output, error;
            assert(copyCommand(o, output, error) == 0, error);
            assert(error.canFind("fscp: copied 3 files (24 B) and 1 link to "), error);
            assert(error.canFind("fscp: verified: castore blake3-"), error);
            assert(readText(buildPath(o.dest, "a/b/run")) == "#!/bin/sh\n");
        }
}

/// XV2: a source file rewritten after the separate pass fails the copy; the
/// inline pass hashes what it copied, and passes.
@("fileset_tools.commands.XV2.sourceChangedBetweenPasses")
@system unittest
{
    auto f = Fixture.make("between");
    scope (exit) f.remove();
    void change() { write(buildPath(f.src, "top.txt"), "changed"); }

    auto separate = options(f, f.dest("separate"));
    separate.afterSourceHash = &change;
    string output, error;
    assert(copyCommand(separate, output, error) == 1);
    assert(error.canFind("differs from the source: top.txt holds 7 bytes, not 3"), error);
    assert(error.canFind("left at " ~ separate.dest ~ " for inspection"), error);
    assert(readText(buildPath(separate.dest, "top.txt")) == "changed", "the copy stays");

    write(buildPath(f.src, "top.txt"), "top");
    auto inline = options(f, f.dest("inline"));
    inline.verify = VerifyMode.inline;
    inline.afterCopy = null;
    assert(copyCommand(inline, output, error) == 0, error);
}

/// XV5: a member changed after the copy wrote it fails the copy, naming it,
/// and the destination keeps every member.
@("fileset_tools.commands.XV5.mismatch")
@system unittest
{
    auto f = Fixture.make("mismatch");
    scope (exit) f.remove();
    auto o = options(f, f.dest("out"));
    o.afterCopy = () { setAttributes(buildPath(o.dest, "a/b/run"), octal!644); };
    string output, error;
    assert(copyCommand(o, output, error) == 1);
    assert(error.canFind("a/b/run lost its executable bit"), error);
    assert(error.canFind("  source  castore blake3-") && error.canFind("  copy    castore blake3-"), error);
    foreach (p; ["top.txt", "a/one.d", "a/b/run", "link"])
        assert(exists(buildPath(o.dest, p)), p);
}

/// XC2: a directory where a member goes is refused, `--force` or not; XC5:
/// a dry run over an existing path refuses as the copy would.
@("fileset_tools.commands.XC2.directoryInTheWay")
@system unittest
{
    auto f = Fixture.make("inway");
    scope (exit) f.remove();
    auto o = options(f, f.dest("out"));
    mkdirRecurse(buildPath(o.dest, "top.txt"));
    string output, error;
    foreach (force; [false, true])
    {
        o.force = force;
        assert(copyCommand(o, output, error) == 1);
        assert(error.canFind("1 directory is where a member goes"), error);
    }
    assert(!exists(buildPath(o.dest, "a")), "nothing written");

    auto again = options(f, f.dest("again"));
    assert(copyCommand(again, output, error) == 0, error);
    again.dryRun = true;
    assert(copyCommand(again, output, error) == 1 && error.canFind("4 paths exist"), error);
}

/// XV4: --tree-hashes checks the NAR and git names too, and they are the
/// names `evaluate` gives the source.
@("fileset_tools.commands.XV4.treeHashes")
@system unittest
{
    auto f = Fixture.make("names");
    scope (exit) f.remove();
    const theirs = evaluate(Root(dir: f.src), "all()", withIds: true);
    auto o = options(f, f.dest("out"));
    o.treeHashes = true;
    string output, error;
    assert(copyCommand(o, output, error) == 0, error);
    foreach (name; [theirs.castore, theirs.narHash, theirs.gitTree])
        assert(error.canFind("source " ~ name) && error.canFind("copy   " ~ name), name ~ "\n" ~ error);
    assert(error.canFind("verified: castore, NarHash and git tree"), error);
}
