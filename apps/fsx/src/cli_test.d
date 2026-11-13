/// `fsx`'s command line (`XA`, `XC`, `XL`, docs/specs/fsx), run end to end.
module cli_test;

version (unittest):
version (Posix):

import std.algorithm.searching : canFind, startsWith;
import std.array : split;
import std.conv : octal, text;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, setAttributes, symlink, tempDir, write;
import std.path : buildPath;

import cli : runFsxTo, subcommandOfName;

// `top.txt`, `a/one.d`, an executable `a/b/run` and a link `link`.
private struct Fixture
{
    string top, src;

    static Fixture make(string label)
    {
        import std.process : thisProcessID;

        Fixture f;
        f.top = buildPath(tempDir, text("fsx-", thisProcessID, "-", label));
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

    void remove() => rmdirRecurse(top);
}

private struct Run
{
    int status;
    string output, error;
}

private Run run(string[] args...)
{
    Run r;
    r.status = runFsxTo(args.dup, r.output, r.error);
    return r;
}

/// XA1: `fscp`, `fsls` and `fsdiff` are `fsx cp`, `ls` and `diff`; any other
/// name is `fsx`.
@("fsx.XA1.names")
@system unittest
{
    assert(subcommandOfName("/usr/bin/fscp") == "cp");
    assert(subcommandOfName("fsls") == "ls");
    assert(subcommandOfName("./fsdiff") == "diff");
    assert(subcommandOfName("/usr/bin/fsx") is null);

    auto f = Fixture.make("names");
    scope (exit) f.remove();
    const viaFsx = run("fsx", "ls", "--src", f.src, "--long");
    const viaName = run("/somewhere/fsls", "--src", f.src, "--long");
    assert(viaFsx.status == 0 && viaFsx == viaName, viaFsx.error ~ viaName.error);
}

/// XA2, XA3: --filter and --filter-file select alike; both is a usage error;
/// a query that does not parse exits 1; a missing option exits 2.
@("fsx.XA2.filter")
@system unittest
{
    auto f = Fixture.make("filter");
    scope (exit) f.remove();
    const file = buildPath(f.top, "q.fileset");
    write(file, "a/**");
    const inline = run("fsls", "--src", f.src, "--filter", "a/**");
    const fromFile = run("fsls", "--src", f.src, "--filter-file", file);
    assert(inline.status == 0 && inline.output == "a/b/run\na/one.d\n", inline.output ~ inline.error);
    assert(fromFile.output == inline.output);

    assert(run("fsls", "--src", f.src, "--filter", "a/**", "--filter-file", file).status == 2);
    const bad = run("fsls", "--src", f.src, "--filter", "(");
    assert(bad.status == 1 && bad.error.startsWith("fsls: (: "), bad.error);
    assert(run("fscp", "--src", f.src).status == 2, "--dst is required");
    assert(run("fsx", "cp", "--src", f.src, "--dst", "x", "--bogus").status == 2);
}

/// XA5: the default build has no diff, and says so.
@("fsx.XA5.noDiff")
@system unittest
{
    version (FsxDiff) {} else
    {
        const r = run("fsdiff", "a", "b");
        assert(r.status == 2 && r.error.canFind("built without diff"), r.error);
    }
}

/// XC, XV: fscp copies the fixture, verified; a second copy refuses; the
/// dry run lists; an iroh ticket is named as one.
@("fsx.XC.cp")
@system unittest
{
    auto f = Fixture.make("cp");
    scope (exit) f.remove();
    const dst = buildPath(f.top, "out");
    const copy = run("fscp", "--src", f.src, "--dst", dst, "--filter", "a/** | link");
    assert(copy.status == 0, copy.error);
    assert(copy.error.canFind("fscp: copied 2 files (21 B) and 1 link to " ~ dst), copy.error);
    assert(copy.error.canFind("fscp: verified: castore blake3-"), copy.error);
    assert(!exists(buildPath(dst, "top.txt")));

    const again = run("fscp", "--src", f.src, "--dst", dst, "--filter", "a/** | link");
    assert(again.status == 1 && again.error.canFind("3 paths exist"), again.error);
    const dry = run("fscp", "--src", f.src, "--dst", buildPath(f.top, "dry"), "-n");
    assert(dry.status == 0 && dry.output.split('\n').length == 5 && !exists(buildPath(f.top, "dry")), dry.output);

    const ticket = run("fscp", "--src", "iroh:blobadd6ooplaj7pgoz7sebzgm5oe5gpaqqyznbno4evdgft76adzf6nk",
        "--dst", dst);
    assert(ticket.status == 1 && ticket.error.canFind("names an iroh ticket"), ticket.error);
}

/// XL1–XL3: sorted paths, NUL-separated, the long form, and the tree.
@("fsx.XL.ls")
@system unittest
{
    auto f = Fixture.make("ls");
    scope (exit) f.remove();
    assert(run("fsls", "--src", f.src).output == "a/b/run\na/one.d\nlink\ntop.txt\n");
    assert(run("fsls", "--src", f.src, "-0").output == "a/b/run\0a/one.d\0link\0top.txt\0");
    assert(run("fsls", "--src", f.src, "-l").output
        == "x\t10\ta/b/run\nf\t11\ta/one.d\nl\t7\tlink\t-> a/one.d\nf\t3\ttop.txt\n");
    assert(run("fsls", "--src", f.src, "--tree").output == ".\n"
        ~ "├── a/\n"
        ~ "│   ├── b/\n"
        ~ "│   │   └── run\n"
        ~ "│   └── one.d\n"
        ~ "├── link -> a/one.d\n"
        ~ "└── top.txt\n");

    // XL4: the numbers go to standard error, and the listing is unchanged.
    const plain = run("fsls", "--src", f.src);
    const withIds = run("fsls", "--src", f.src, "--tree-hashes", "--stats");
    assert(withIds.output == plain.output);
    assert(withIds.error.canFind("castore   blake3-") && withIds.error.canFind("members"), withIds.error);
}
