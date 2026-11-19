/**
The generators' oracles (fileset explorer `FXE`, testing.md): each target's
code, run by the tool that defines its meaning on a materialized tree, lists
exactly the members the fileset library resolves the query to.

A test skips when its tool is not on `PATH`; `nix` also needs the flake's
`nixpkgs` input (`$SPARKLES_FLAKE_INPUT_NIXPKGS`).

Excluded from the `library` configuration.
*/
module sparkles.build_primitives.fileset.emit.testing;

import std.algorithm.iteration : filter, map, splitter;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join, replace;
import std.conv : text;
import std.file : exists, mkdirRecurse, write;
import std.path : baseName, buildPath;
import std.process : Config, environment, execute;

import sparkles.build_primitives.fileset.emit : emit, EmitOptions, Emitted, NixGlobs, Target;
import sparkles.build_primitives.fileset.emit.nix : NixParts;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.query : compileQuery, globText, parseQuery, Query;
import sparkles.build_primitives.fileset.testing : machineResolve, materialize, openFixture, removeScratchTree,
    scratchTree;
import sparkles.build_primitives.fileset.value : Filesets;
import sparkles.build_primitives.git_env : gitChildEnvironment, runGit;
import sparkles.test_runner.skip : skipTest;

/// The tree every oracle runs on: a directory named like a `*.d` file, a file
/// and a directory both named `x`, dotfiles, an executable, nesting.
enum string oracleTree = "src/app.d = a\nsrc/lib.d = b\nsrc/lib_test.d = t\nsrc/x.d/inner.txt = i\n"
    ~ "src/util/strings.d = s\ndocs/guide.md = g\ndocs/sub/x.md = x\nREADME.md = r\ndub.sdl = d\n"
    ~ "x = 1\na/x = 2\nx2/x = 3\nx2/y = 4\n.hidden/h.d = h\nbuild/app.o = o\nbuild/sub/b.o = p\n"
    ~ "bin/run +x = r\nweird name.txt = w\n";

/// The queries every target is tried on.
immutable string[] corpus = [
    "**/*.d",
    "*.d",
    "src/*.d",
    "src/**",
    "README.md",
    "x",
    "**/x",
    "x/",
    "x2",
    "*.{d,md}",
    "**/*.{d,md}",
    "src/**/*.d - **/*_test.d",
    "all() - build/** - bin/**",
    "**/*.md | **/dub.sdl",
    "(src/** - **/*_test.d) | (docs/** - docs/sub/**)",
    "(docs/** | README.md) - **/*.md",
    "src/** & **/*.d",
    "src/** & docs/**",
    "fileFilter(hasExt(d))",
    "fileFilter(name == x)",
    "fileFilter(hasExt(d) && name != app.d)",
    "fileFilter(name == *_test.d)",
    "fileFilter(name == \"*_test.d\")",
    "all()",
    "none()",
    "exec()",
    "a - (b - c)",
    "src/[al]*.d",
    "src/?pp.d",
    "\"weird name.txt\"",
    "\"weird \"*.txt",
    "**/x - x2/**",
    "src - src/x.d",
    // Names at any depth, which Nix writes as a `fileFilter` where no
    // directory matches them (`**/*.d` is not one: `src/x.d/`).
    "**/*.md",
    "**/*.{md,sdl,o}",
    "docs/**/*.md",
    "**/{*.md,run,*.o}",
    "build/**/*.o - **/b.*",
];

/// The members of `query` over `tree`, sorted.
string[] membersOf(string tree, string query) @system
{
    auto f = openFixture(tree);
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Rights;

    auto root = openRoot!(Rights.readOnly)(&f.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    auto all = (() @trusted {
        string[] paths;
        foreach (line; tree.splitter('\n'))
            if (line.length)
                paths ~= line.splitter(' ').front;
        return paths;
    })();
    auto c = compileQuery(parseQuery(query), sets, () @safe => all);
    assert(c.ok, query ~ ": " ~ c.error.message);
    auto got = machineResolve(root.value.borrow, sets, c.set).members;
    sort(got);
    return got;
}

// Runs `cmd` through the shell in `dir`, with git's environment cleaned.
private string shell(string cmd, string dir) @system
{
    const r = execute(["sh", "-c", cmd], gitChildEnvironment(), Config.newEnv, size_t.max, dir);
    assert(r.status == 0, text("`", cmd, "` failed:\n", r.output));
    return r.output;
}

private string[] lines(string output) @safe
{
    auto ls = output.splitter('\n').filter!(l => l.length > 0).map!(l => l.idup).array;
    sort(ls);
    return ls;
}

private string realPathOf(string path) @safe
{
    version (Posix)
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.conv : to;
        import std.string : toStringz;

        return (() @trusted {
            auto p = realpath(path.toStringz, null);
            if (p is null)
                return path;
            scope (exit) free(p);
            return p.to!string;
        })();
    }
    else
        return path;
}

private bool onPath(string tool) @system
{
    return execute(["sh", "-c", "command -v " ~ tool]).status == 0;
}

/**
Emits every corpus query for `t`; for each accepted one, `oracle` lists the
files the code selects on the materialized tree. Returns the numbers accepted
and refused.
*/
private size_t[2] check(Target t, string[] delegate(string code, string query, string dir) @system oracle,
    EmitOptions o = EmitOptions.init, string tree = oracleTree) @system
{
    size_t accepted, refused;
    foreach (query; corpus)
    {
        const q = parseQuery(query);
        auto want = membersOf(tree, query);
        EmitOptions oo = o;
        oo.members = want;
        const e = emit(t, q, oo);
        if (!e.ok)
        {
            ++refused;
            assert(e.reason.length, query);
            continue;
        }
        ++accepted;
        const dir = scratchTree("emit-" ~ text(t));
        scope (exit) removeScratchTree(dir);
        materialize(tree, dir);
        auto got = oracle(e.code, query, dir);
        sort(got);
        assert(got == want, text(t, " `", query, "`:\n  the tool lists ", got, "\n  the fileset holds ", want,
            "\n--- code ---\n", e.code));
    }
    return [accepted, refused];
}

/// FXE6: rsync's filter rules transfer exactly the members.
@("fileset.emit.oracle.rsync")
@system unittest
{
    if (!onPath("rsync"))
        return skipTest("rsync is not on PATH");
    const n = check(Target.rsync, (code, query, dir) {
        const rules = dir ~ ".rules";
        write(rules, code);
        const dest = dir ~ ".dest";
        mkdirRecurse(dest);
        scope (exit) removeScratchTree(dest);
        const out_ = shell("rsync -r --dry-run --prune-empty-dirs --out-format=%n --filter='merge " ~ rules
            ~ "' ./ " ~ dest ~ "/", dir);
        return lines(out_).filter!(l => !l.endsWith("/")).array;
    });
    assert(n[0] >= 15 && n[1] >= 3, text(n));
}

/// FXE5: a repository with the emitted `.gitignore` leaves exactly the
/// members unignored.
@("fileset.emit.oracle.gitignore")
@system unittest
{
    const n = check(Target.gitignore, (code, query, dir) {
        assert(runGit(["init", "-q"], dir).status == 0);
        write(buildPath(dir, ".gitignore"), code);
        const r = runGit(["ls-files", "--others", "--exclude-standard"], dir);
        assert(r.status == 0, r.output);
        return lines(r.output).filter!(l => l != ".gitignore").array;
    });
    assert(n[0] >= 15 && n[1] >= 3, text(n));
}

/// FXE4: `git ls-files` with the emitted pathspecs lists exactly the members.
@("fileset.emit.oracle.gitPathspec")
@system unittest
{
    const n = check(Target.gitPathspec, (code, query, dir) {
        assert(runGit(["init", "-q"], dir).status == 0);
        assert(runGit(["add", "-A"], dir).status == 0);
        const cmd = code.splitter('\n').filter!(l => l.startsWith("git ")).front;
        return lines(shell(cmd, dir));
    });
    assert(n[0] >= 12 && n[1] >= 3, text(n));
}

/// FXE7: the emitted tar command archives exactly the members.
@("fileset.emit.oracle.tar")
@system unittest
{
    if (!onPath("tar"))
        return skipTest("tar is not on PATH");
    const n = check(Target.tar, (code, query, dir) {
        const archive = "../" ~ baseName(dir) ~ ".tar";
        const cmd = code.splitter('\n').filter!(l => l.startsWith("tar ")).front
            .replace("-cf archive.tar", "-cf " ~ archive);
        shell(cmd, dir);
        scope (exit) shell("rm -f " ~ archive, dir);
        return lines(shell("tar -tf " ~ archive, dir)).filter!(l => !l.endsWith("/"))
            .map!(l => l.startsWith("./") ? l[2 .. $] : l).array;
    });
    assert(n[0] >= 4 && n[1] >= 10, text(n));
}

/// FXE10: dub's `sourceFiles` are the members.
@("fileset.emit.oracle.dub")
@system unittest
{
    if (!onPath("dub"))
        return skipTest("dub is not on PATH");
    const n = check(Target.dub, (code, query, dir) {
        // The tree has a `dub.sdl` of its own: the package sits beside it,
        // naming the tree's files by absolute path.
        const pkg = dir ~ ".pkg";
        mkdirRecurse(pkg);
        scope (exit) removeScratchTree(pkg);
        const dirSlash = dir.replace("\\", "/");
        write(buildPath(pkg, "dub.sdl"), "name \"fx\"\ntargetType \"library\"\n"
            ~ code.replace("sourceFiles \"", "sourceFiles \"" ~ dirSlash ~ "/")
                .replace("\" \"", "\" \"" ~ dirSlash ~ "/"));
        if (!code.canFind("sourceFiles \""))
            return string[].init; // no files: dub refuses a library without any
        const r = execute(["dub", "describe", "--root", pkg, "--data=source-files", "--skip-registry=all",
            "--data-list"]);
        assert(r.status == 0, r.output);
        const prefix = dirSlash ~ "/";
        return lines(r.output).map!(l => l.replace("\\", "/"))
            .filter!(l => l.startsWith(prefix)).map!(l => l[prefix.length .. $]).array;
    });
    assert(n[0] >= 15 && n[1] >= 1, text(n)); // refused: a member dub hands the linker
}

/// FXE3: `lib.fileset.toList` of the emitted expression is the members, with
/// the glob shim, and with snapshots.
@("fileset.emit.oracle.libFileset")
@system unittest
{
    const nixpkgs = environment.get("SPARKLES_FLAKE_INPUT_NIXPKGS", "");
    if (nixpkgs.length == 0 || !onPath("nix"))
        return skipTest("nix or $SPARKLES_FLAKE_INPUT_NIXPKGS is missing");
    foreach (mode; [NixGlobs.shim, NixGlobs.expand])
    {
        EmitOptions o;
        o.nixGlobs = mode;
        o.expand = (string glob) @trusted => membersOf(oracleTree, globText(glob));
        size_t accepted, named; // named: globs written as a `fileFilter`
        foreach (query; corpus)
        {
            const q = parseQuery(query);
            auto p = NixParts.of(q, o);
            if (!p.ok)
                continue;
            ++accepted;
            named += !query.canFind("fileFilter") && p.fileset.canFind("fs.fileFilter");
            const dir = scratchTree("emit-nix");
            scope (exit) removeScratchTree(dir);
            materialize(oracleTree, dir);
            write(buildPath(dir, "oracle.nix"), p.render(
                "map (p: lib.removePrefix (toString root + \"/\") (toString p)) (fs.toList %s)"));
            const r = execute(["nix", "eval", "--impure", "--json", "--expr",
                "import \"" ~ buildPath(realPathOf(dir), "oracle.nix") ~ "\" { lib = import \"" ~ nixpkgs ~ "/lib\"; }"]);
            {
                import std.file : readText;

                assert(r.status == 0, text(query, ":\n", r.output, "\n--- oracle.nix ---\n",
                    readText(buildPath(dir, "oracle.nix"))));
            }
            import std.json : parseJSON;

            string[] got;
            foreach (v; parseJSON(r.output.splitter('\n').filter!(l => l.startsWith("[")).front).array)
                got ~= v.str;
            got = got.filter!(g => g != "oracle.nix").array;
            sort(got);
            auto want = membersOf(oracleTree, query);
            assert(got == want, text(mode, " `", query, "`:\n  nix lists ", got, "\n  the fileset holds ",
                want, "\n--- code ---\n", p.render("%s")));
        }
        assert(accepted >= 25 && named >= 5, text(mode, ": ", accepted, " accepted, ", named, " named"));
    }
}

/// FXE8: `cargo package --list` of a crate with the emitted `include` is the
/// members.
@("fileset.emit.oracle.cargo")
@system unittest
{
    if (!onPath("cargo"))
        return skipTest("cargo is not on PATH");
    enum crate = oracleTree ~ "Cargo.toml = x\nsrc/lib.rs = x\n";
    EmitOptions o;
    o.cargoAlways = ["Cargo.toml", "README.md"];
    size_t accepted, refused;
    foreach (query; corpus.map!(q => "(" ~ q ~ ") | Cargo.toml | README.md | src/lib.rs").array ~ ["*.d"])
    {
        const q = parseQuery(query);
        auto want = membersOf(crate, query);
        const e = emit(Target.cargo, q, o);
        if (!e.ok)
        {
            ++refused;
            continue;
        }
        ++accepted;
        const dir = scratchTree("emit-cargo");
        scope (exit) removeScratchTree(dir);
        materialize(crate, dir);
        const toml = e.code.replace("[package]\n",
            "[package]\nname = \"fx\"\nversion = \"0.0.0\"\nedition = \"2021\"\nlicense = \"MIT\"\n"
            ~ "description = \"x\"\n");
        write(buildPath(dir, "Cargo.toml"), toml);
        const r = execute(["cargo", "package", "--list", "--allow-dirty", "--offline"], null,
            Config.stderrPassThrough,
            size_t.max, dir);
        assert(r.status == 0, text(query, ":\n", r.output));
        auto got = lines(r.output).filter!(l => l != "Cargo.toml.orig" && l != "Cargo.lock")
            .map!(l => l.replace("\\", "/")).array;
        assert(got == want, text("cargo `", query, "`:\n  cargo lists ", got, "\n  the fileset holds ", want,
            "\n--- code ---\n", e.code));
    }
    assert(accepted >= 10 && refused >= 1, text(accepted, " ", refused));
}

/// FXE9: Bazel's `glob` in a one-package workspace is the members.
@("fileset.emit.oracle.bazel")
@system unittest
{
    if (!onPath("bazel"))
        return skipTest("bazel is not on PATH");
    size_t accepted;
    foreach (query; corpus)
    {
        const q = parseQuery(query);
        const e = emit(Target.bazel, q);
        if (!e.ok)
            continue;
        ++accepted;
        const dir = scratchTree("emit-bazel");
        scope (exit) removeScratchTree(dir);
        materialize(oracleTree, dir);
        const globCall = e.code.splitter('\n').filter!(l => !l.startsWith("#")).join("\n");
        write(buildPath(dir, "BUILD.bazel"), "filegroup(name = \"x\", srcs = " ~ globCall ~ ")\n");
        write(buildPath(dir, "MODULE.bazel"), "");
        const r = execute(["bazel", "--batch", "query", "labels(srcs, //:x)", "--output=label"], null,
            Config.none, size_t.max, dir);
        assert(r.status == 0, text(query, ":\n", r.output));
        // The oracle's own files are not the tree's.
        auto got = lines(r.output).filter!(l => l.startsWith("//:")).map!(l => l[3 .. $])
            .filter!(l => l != "BUILD.bazel" && l != "MODULE.bazel").array;
        auto want = membersOf(oracleTree, query);
        sort(got);
        assert(got == want, text("bazel `", query, "`:\n  bazel lists ", got, "\n  the fileset holds ", want));
    }
    assert(accepted >= 10, text(accepted));
}
