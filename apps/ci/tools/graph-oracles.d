#!/usr/bin/env dub
/+ dub.sdl:
    name "graph_oracles"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:build-graph" path="../../.."
    dependency "sparkles:unittest-layout" path="../../.."
    dependency "sparkles:d-source" path="../../.."
    // The driver the oracles run the graph through, and ci's statement of
    // the workspace inputs it plans against.
    dflags "-I=$PACKAGE_DIR/../src" "-i=repository_inputs" "-i=graph_driver" platform="ldc"

    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
E3's gate (build-graph PLAN): the oracles of the build graph's testing
document that run through the test-only driver. Each runs the graph on
fixture packages it adds to the worktree for the length of its check
(`libs/zz-oracle-<name>`, listed in the root recipe meanwhile) against a
scratch store of its own, and prints a verdict per step:

    dub run --single apps/ci/tools/graph-oracles.d -- [--only=<oracle>]... [<root>]

`--only=16` runs one oracle's steps; without it every oracle runs. Needs
the dev shell: its toolchain, `SPARKLES_DUB_SOURCES` and `strace`. A check
that is interrupted can leave a fixture behind; the next run removes it.
*/
module graph_oracles;

import core.time : msecs, seconds;
import std.algorithm : all, canFind, filter, map, sort, startsWith;
import std.array : array, join, replace, split;
import std.conv : text;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.process : thisProcessID;
import std.stdio : stderr, writeln;
import std.sumtype : match;

import sparkles.build_graph.actions : ActionKind, Tools;
import sparkles.build_primitives.task.action : ProcessAction;


import graph_driver;

/// The worktree the oracles run in, absolute.
__gshared string root;
/// The scratch directory every oracle's stores lie beneath.
__gshared string scratch;

int main(string[] args)
{
    const only = args.filter!(a => a.startsWith("--only=")).map!(a => a["--only=".length .. $]).array;
    const positional = args[1 .. $].filter!(a => !a.startsWith("--")).array;
    root = buildNormalizedPath(absolutePath(positional.length ? positional[0] : "."));
    scratch = buildPath(tempDir, text("graph-oracles-", thisProcessID));
    mkdirRecurse(scratch);
    scope (exit)
        if (exists(scratch))
            rmdirRecurse(scratch);
    removeStaleFixtures();

    bool ok = true;
    size_t ran;
    foreach (ref o; oracles)
    {
        if (only.length && !only.canFind(o.id))
            continue;
        foreach (v; o.check())
        {
            writeln(v.failure.length ? "FAIL " : "pass ", "oracle ", o.id, " ", v.step, ": ",
                v.failure.length ? v.failure : v.detail);
            ok &= v.failure.length == 0;
            ++ran;
        }
    }
    writeln(ran, " steps; ", ok ? "all pass" : "some fail");
    return ok ? 0 : 1;
}

/// One step's verdict: a failure, or what held.
struct Verdict
{
    string step;    ///
    string failure; /// empty when it holds
    string detail;  /// what held
}

/// An oracle: its id (`16`), and its check.
struct Oracle
{
    string id;
    Verdict[] function() check;
}

immutable Oracle[] oracles = [
    Oracle("10", &oracle10),
    Oracle("11", &oracle11),
    Oracle("13", &oracle13),
    Oracle("16", &oracle16),
    Oracle("17", &oracle17),
    Oracle("18", &oracle18),
    Oracle("19", &oracle19),
    Oracle("24", &oracle24),
];

// === Fixtures ===

/// The prefix of a fixture package's name and directory.
enum fixturePrefix = "zz-oracle-";

/**
A temporary sub-package of the worktree, `libs/zz-oracle-<name>`, listed in
the root recipe while it lives. Its files are written as given; the root
recipe's bytes are restored and the directory removed when it goes.
*/
struct Fixture
{
    string name; /// the package's name, `zz-oracle-<name>`
    string dir;  /// its directory, absolute
    private string recipe; // the root recipe as it was

    @disable this(this);

    static Fixture add(string name, string[string] files)
    {
        Fixture f;
        f.name = fixturePrefix ~ name;
        f.dir = buildPath(root, "libs", f.name);
        if (exists(f.dir))
            rmdirRecurse(f.dir);
        foreach (path, content; files)
            f.put(path, content);
        f.recipe = readText(buildPath(root, "dub.sdl"));
        write(buildPath(root, "dub.sdl"), withSubPackage(f.recipe, f.name));
        return f;
    }

    ~this()
    {
        if (!dir.length)
            return;
        write(buildPath(root, "dub.sdl"), recipe);
        if (exists(dir))
            rmdirRecurse(dir);
    }

    /// Writes `content` to `path`, beneath the package.
    void put(string path, string content)
    {
        mkdirRecurse(dirName(buildPath(dir, path)));
        write(buildPath(dir, path), content);
    }

    /// The task id prefix of the package's actions of `kind` (`compile`).
    string task(string kind) const => kind ~ ":sparkles." ~ name ~ ":";
}

/// Removes the fixtures an interrupted check left behind, and their lines in
/// the root recipe.
void removeStaleFixtures()
{
    import std.file : dirEntries, SpanMode;
    import std.string : lineSplitter;

    foreach (e; dirEntries(buildPath(root, "libs"), SpanMode.shallow))
        if (e.isDir && e.name.canFind("/" ~ fixturePrefix))
            rmdirRecurse(e.name);
    const recipe = readText(buildPath(root, "dub.sdl"));
    string kept;
    foreach (line; recipe.lineSplitter)
        if (!line.canFind("libs/" ~ fixturePrefix))
            kept ~= line ~ "\n";
    if (kept != recipe)
        write(buildPath(root, "dub.sdl"), kept);
}

/**
A fixture library's recipe: its `src` imported, the repository's preview
flags, and the test runner in its `unittest` configuration. `dependencies`
names other packages (`zz-oracle-b`) it depends on in both, and
`cImportPaths` its C include roots and `versions` its version identifiers. Written from the `dub.sdl` schema
(SDE9), as no recipe here is written as text.
*/
string recipeOf(string name, string[] dependencies = null, string[] cImportPaths = null, string[] versions = null)
{
    import sparkles.build_primitives.dub_manifest : DubConfiguration, DubDependency, DubManifest,
        DubPlatformValues;
    import sparkles.wired.sdl : toSDL;

    static DubPlatformValues values(string[] v...)
    {
        DubPlatformValues p;
        p.values = v.dup;
        return p;
    }
    static DubDependency dependency(string package_)
    {
        DubDependency d;
        d.name = "sparkles:" ~ package_;
        d.path = "../..";
        return d;
    }
    DubManifest m;
    m.name = fixturePrefix ~ name;
    m.targetPath = "build";
    m.importPaths = [values("src")];
    m.dflags = [values("-preview=in", "-preview=dip1000")];
    if (cImportPaths.length)
        m.cImportPaths = [values(cImportPaths)];
    if (versions.length)
        m.versions = [values(versions)];
    DubConfiguration library, unittests;
    library.name = "library";
    library.targetType = "library";
    unittests.name = "unittest";
    unittests.dependencies = [dependency("test-runner")];
    unittests.dflags = [values("-checkaction=context", "-allinst")];
    foreach (d; dependencies)
    {
        library.dependencies ~= dependency(d);
        unittests.dependencies ~= dependency(d);
    }
    m.configurations = [library, unittests];
    const sdl = toSDL(m);
    assert(sdl.hasValue, sdl.error.toString);
    return sdl.value[].idup;
}

/// The root recipe `text` with the fixture `name` among its sub-packages,
/// through the lossless editor: nothing else of it changes.
string withSubPackage(string text, string name)
{
    import std.experimental.allocator.mallocator : Mallocator;
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.build_primitives.dub_manifest : DubManifest, DubSubPackage, decodeDubManifestLenient;
    import sparkles.wired.sdl : parseSdlDocument, sdlDubRecipe, sdlEditor, updateSDL;

    auto parsed = parseSdlDocument!sdlDubRecipe(text);
    assert(parsed.hasValue, parsed.error.toString);
    auto decoded = decodeDubManifestLenient(parsed.document);
    assert(decoded.hasValue, decoded.error.toString);
    DubManifest m = cast() decoded.value;
    DubSubPackage s;
    s.path = "libs/" ~ name;
    m.subPackages ~= s;
    auto editor = sdlEditor!sdlDubRecipe(parsed.document, text);
    updateSDL(editor, parsed.document.root, m);
    UniqueBuffer!char output;
    Mallocator allocator;
    const written = editor.write(output, allocator);
    assert(!written.hasError, written.error.toString);
    return output[].idup;
}

// === Runs ===

/// A scratch cache directory of its own, empty, beneath `scratch`.
string freshCache(string label)
{
    static size_t made;
    const dir = buildPath(scratch, text(label, "-", ++made));
    mkdirRecurse(dir);
    return dir;
}

/// Runs the test root of `pkg` against the store beneath `cache`, in a run
/// directory of its own.
GraphRun run(string pkg, string cache, RunOptions o = RunOptions.init, string at = null)
{
    static size_t runs;
    o.cache = cache;
    o.into = buildPath(cache, "runs", text("oracle-", ++runs));
    return runGraph(at.length ? at : root, pkg, o);
}

/// The one task of `g` whose id starts with `prefix`, or null.
string taskOf(ref const GraphRun g, string prefix)
{
    string found;
    foreach (ref a; g.plan.graph.actions)
        if (a.id.text.startsWith(prefix))
        {
            if (found.length)
                return null;
            found = a.id.text;
        }
    return found;
}

/// Whether `task` executed in `g`.
bool executed(ref const GraphRun g, string task) => g.stats.executedTasks.canFind(task);

/// Whether `task` has a result in the store after `g` (it was served or published).
bool stored(ref const GraphRun g, string task) => (task in g.stats.resultKeys) !is null;

/// The last lines of `log`, for a failure's detail.
string tailOf(string log, size_t n = 12)
{
    import std.string : lineSplitter;

    auto lines = log.lineSplitter.array;
    return "\n    " ~ lines[lines.length > n ? $ - n : 0 .. $].join("\n    ");
}

/// The lines of `log` that report a compiler's error.
string[] errorLines(string log)
{
    import std.string : lineSplitter;

    string[] lines;
    foreach (line; log.lineSplitter)
        if (line.canFind("Error:"))
        {
            // The reporter prefixes each line with its task; the compiler's
            // own text follows the `]`.
            const close = line.canFind("] ") ? line[line.countUntil("] ") + 2 .. $] : line;
            lines ~= close.idup;
        }
    return lines.sort.release;
}

private ptrdiff_t countUntil(string s, string needle)
{
    import std.string : indexOf;

    return s.indexOf(needle);
}

/// Replaces, in `p`'s plan, the argument vector of the actions whose id
/// starts with `prefix` by `wrap(argv)`.
void wrapActions(ref Planned p, string prefix, string[] delegate(string[]) wrap)
{
    foreach (ref a; p.graph.actions)
        if (a.id.text.startsWith(prefix))
            a.action.match!(
                (ref ProcessAction pa) { pa.argv = wrap(pa.argv); },
                (ref _) {});
}

/// A tool by absolute path: a build action's `PATH` is empty (BGA4).
string tool(string name)
{
    static string[string] found;
    if (auto p = name in found)
        return *p;
    return found[name] = onPath(name);
}

/// A shell by absolute path.
string sh() => tool("sh");

// === Oracle 11: test actions ===

/// Step 2: a test that declares no runtime inputs runs on every request.
/// (Step 1, the recording `dub`, is every run's BGX1 check; step 3 is E4's.)
Verdict[] oracle11()
{
    auto f = Fixture.add("o11", [
        "dub.sdl": recipeOf("o11"),
        "src/sparkles/zz_o11/pass.d": "module sparkles.zz_o11.pass;\n\nunittest\n{\n    assert(1 + 1 == 2);\n}\n",
    ]);
    const cache = freshCache("o11");
    auto first = run(f.name, cache);
    auto second = run(f.name, cache);
    const test = taskOf(first, f.task("test"));
    if (first.error.length || second.error.length)
        return [Verdict("step 2", "the run failed to start: " ~ first.error ~ second.error)];
    if (first.exitCode != 0 || second.exitCode != 0)
        return [Verdict("step 2", text("the runs exited ", first.exitCode, " and ", second.exitCode))];
    const compile = taskOf(first, f.task("compile"));
    return [Verdict("step 2",
        !executed(first, test) || !executed(second, test) ? "the test did not run on the second request"
        : executed(second, compile) ? "the second request recompiled" : null,
        "the test ran on both requests, its compile reused on the second")];
}

// === Oracle 13: hidden edges at execution time ===

/// An ImportC source that includes a header of a package it does not depend
/// on fails its compile, naming the header and that package, and leaves no
/// result; the same include through a declared dependency's C import root
/// passes.
Verdict[] oracle13()
{
    Verdict[] vs;
    {
        auto other = Fixture.add("o13b", [
            "dub.sdl": recipeOf("o13b", null, ["include"]),
            "src/sparkles/zz_o13b/empty.d": "module sparkles.zz_o13b.empty;\n",
            "include/x.h": "#define ZZ_ANSWER 42\n",
        ]);
        auto reach = Fixture.add("o13a", [
            "dub.sdl": recipeOf("o13a"),
            "src/sparkles/zz_o13a/x_c.c": "#include \"../../../../zz-oracle-o13b/include/x.h\"\n"
                ~ "int zz_answer(void);\n",
            "src/sparkles/zz_o13a/use.d": "module sparkles.zz_o13a.use;\n\nimport sparkles.zz_o13a.x_c;\n\nstatic assert(ZZ_ANSWER == 42);\n",
        ]);
        auto g = run(reach.name, freshCache("o13"));
        const compile = taskOf(g, reach.task("compile"));
        vs ~= Verdict("execution-time reach",
            g.error.length ? g.error
            : g.exitCode == 0 ? "the compile that reached into zz-oracle-o13b passed"
            : !g.log.canFind("read outside its declared roots") || !g.log.canFind("zz-oracle-o13b/include/x.h")
                ? "the failure does not name the header outside its roots" ~ tailOf(g.log)
            : stored(g, compile) ? "the failing compile left a result in the store" : null,
            "the compile failed, naming zz-oracle-o13b/include/x.h, and left no result");
    }
    {
        auto other = Fixture.add("o13d", [
            "dub.sdl": recipeOf("o13d", null, ["include"]),
            "src/sparkles/zz_o13d/empty.d": "module sparkles.zz_o13d.empty;\n",
            "include/x.h": "#define ZZ_ANSWER 42\n",
        ]);
        auto declared = Fixture.add("o13c", [
            "dub.sdl": recipeOf("o13c", ["zz-oracle-o13d"]),
            "src/sparkles/zz_o13c/x_c.c": "#include \"x.h\"\nint zz_answer(void);\n",
            "src/sparkles/zz_o13c/use.d": "module sparkles.zz_o13c.use;\n\nimport sparkles.zz_o13c.x_c;\n\nstatic assert(ZZ_ANSWER == 42);\n",
        ]);
        auto g = run(declared.name, freshCache("o13"));
        vs ~= Verdict("through a declared dependency",
            g.error.length ? g.error : g.exitCode != 0 ? "the include through a declared dependency failed:" ~ tailOf(g.log)
                : null,
            "the same include through zz-oracle-o13d's C import root passes");
    }
    return vs;
}

// === Oracle 16: publication faults ===

Verdict[] oracle16()
{
    Verdict[] vs;
    enum badModule = "module sparkles.zz_o16a.bad;\n\nint f() { return \"not an int\"; }\n";

    // Step 1: a deterministic failure is published, then replayed.
    {
        auto f = Fixture.add("o16a", [
            "dub.sdl": recipeOf("o16a"),
            "src/sparkles/zz_o16a/bad.d": badModule,
        ]);
        const cache = freshCache("o16");
        auto first = run(f.name, cache);
        auto second = run(f.name, cache);
        const compile = taskOf(first, f.task("compile"));
        string why;
        if (first.error.length || second.error.length)
            why = first.error ~ second.error;
        else if (first.exitCode == 0)
            why = "the type error compiled";
        else if (!stored(first, compile))
            why = "the failed compile published no result";
        else if (executed(second, compile))
            why = "the second run executed the failed compile again";
        else if (second.exitCode != first.exitCode)
            why = text("the replay exited ", second.exitCode, ", the run ", first.exitCode);
        else if (errorLines(second.log) != errorLines(first.log))
            why = "the replay's diagnostics differ:\n" ~ errorLines(second.log).join("\n");
        else
        {
            // A second worktree, the fixture copied in: the same failure is
            // served from the shared store.
            const other = secondWorktree();
            scope (exit)
                removeWorktree(other);
            copyFixture(f, other);
            auto third = run(f.name, cache, RunOptions.init, other);
            if (third.error.length)
                why = third.error;
            else if (executed(third, compile))
                why = "a run in a second worktree executed the failed compile";
            else if (errorLines(third.log) != errorLines(first.log) || third.exitCode != first.exitCode)
                why = "the second worktree's replay differs";
        }
        vs ~= Verdict("step 1", why, text("the failure was published and replayed, its diagnostics and exit ",
            first.exitCode, " the same, in the same worktree and another"));
    }

    // Step 2: a failing test leaves no result and runs again.
    {
        auto f = Fixture.add("o16b", [
            "dub.sdl": recipeOf("o16b"),
            "src/sparkles/zz_o16b/fails.d": "module sparkles.zz_o16b.fails;\n\nunittest\n{\n    assert(false);\n}\n",
        ]);
        const cache = freshCache("o16");
        auto first = run(f.name, cache);
        auto second = run(f.name, cache);
        const test = taskOf(first, f.task("test"));
        vs ~= Verdict("step 2",
            first.exitCode == 0 ? "the failing test passed"
            : stored(first, test) ? "the failing test left a result"
            : !executed(second, test) ? "the next request did not run the test" : null,
            "the failing test left no result, and the next request ran it");
    }

    // Step 3: an ending by a signal, a timeout or a cancellation publishes
    // nothing, and the next run compiles.
    {
        auto f = Fixture.add("o16c", [
            "dub.sdl": recipeOf("o16c"),
            "src/sparkles/zz_o16c/ok.d": "module sparkles.zz_o16c.ok;\n\nint g() { return 1; }\n",
        ]);
        string[] failures;
        void ending(string what, RunOptions o)
        {
            const cache = freshCache("o16");
            auto ended = run(f.name, cache, o);
            auto next = run(f.name, cache);
            const compile = taskOf(ended, f.task("compile"));
            if (ended.error.length)
                failures ~= what ~ ": " ~ ended.error;
            else if (ended.exitCode == 0)
                failures ~= what ~ ": the run passed";
            else if (stored(ended, compile))
                failures ~= what ~ ": the ended compile left a result";
            else if (!executed(next, compile))
                failures ~= what ~ ": the next run did not compile";
        }
        RunOptions killed;
        killed.adjustPlan = (ref Planned p) {
            wrapActions(p, f.task("compile"), (string[] argv) => [sh(), "-c", "kill -KILL $$"]);
        };
        ending("SIGKILL", killed);
        RunOptions timedOut;
        timedOut.adjustPlan = (ref Planned p) {
            foreach (ref a; p.graph.actions)
                if (a.id.text.startsWith(f.task("compile")))
                    a.action.match!(
                        (ref ProcessAction pa) {
                            pa.argv = [sh(), "-c", tool("sleep") ~ " 30; exec \"$0\" \"$@\""] ~ pa.argv;
                            pa.timeout = 300.msecs;
                        },
                        (ref _) {});
        };
        ending("timeout", timedOut);
        vs ~= Verdict("step 3 (signal, timeout)", failures.join("; "),
            "a compile killed by SIGKILL and one past its limit left no result, and the next run compiled");
    }
    {
        // A cancellation: a dependency's compile is slow, the package's own
        // fails at once, and fail-fast cancels the slow one.
        auto dep = Fixture.add("o16e", [
            "dub.sdl": recipeOf("o16e"),
            "src/sparkles/zz_o16e/slow.d": "module sparkles.zz_o16e.slow;\n\nint h() { return 2; }\n",
        ]);
        auto f = Fixture.add("o16d", [
            "dub.sdl": recipeOf("o16d", ["zz-oracle-o16e"]),
            "src/sparkles/zz_o16d/bad.d": badModule.replace("o16a", "o16d"),
        ]);
        const cache = freshCache("o16");
        RunOptions o;
        o.failFast = true;
        o.adjustPlan = (ref Planned p) {
            wrapActions(p, dep.task("compile"), (string[] argv) => [sh(), "-c", tool("sleep") ~ " 20; exec \"$0\" \"$@\""] ~ argv);
        };
        auto cancelled = run(f.name, cache, o);
        auto next = run(f.name, cache);
        const slow = taskOf(cancelled, dep.task("compile"));
        vs ~= Verdict("step 3 (cancellation)",
            cancelled.error.length ? cancelled.error
            : !slow.length ? "the dependency's compile is not in the plan"
            : stored(cancelled, slow) ? "the cancelled compile left a result"
            : !executed(next, slow) ? "the next run did not compile the cancelled action" : null,
            "a compile cancelled by fail-fast left no result, and the next run compiled it");
    }

    // Step 4: exiting zero without writing the object fails and publishes nothing.
    {
        auto f = Fixture.add("o16f", [
            "dub.sdl": recipeOf("o16f"),
            "src/sparkles/zz_o16f/ok.d": "module sparkles.zz_o16f.ok;\n\nint g() { return 1; }\n",
        ]);
        RunOptions o;
        o.adjustPlan = (ref Planned p) {
            wrapActions(p, f.task("compile"), (string[] argv) => [sh(), "-c", "exit 0"]);
        };
        auto g = run(f.name, freshCache("o16"), o);
        const compile = taskOf(g, f.task("compile"));
        vs ~= Verdict("step 4",
            g.exitCode == 0 ? "the run passed with no object"
            : !g.log.canFind("exited zero without its declared output") ? "the failure does not name the missing output"
            : stored(g, compile) ? "the compile without its object published a result" : null,
            "a compile that exited zero without its object failed and published nothing");
    }
    return vs;
}

/// A git worktree of the repository at `HEAD`, beneath `scratch`.
string secondWorktree()
{
    import sparkles.build_primitives.git_env : runGit;

    const dir = buildPath(scratch, text("worktree-", thisProcessID));
    const r = runGit(["worktree", "add", "--detach", "--quiet", dir, "HEAD"], root);
    assert(r.status == 0, r.output);
    return dir;
}

/// Removes a worktree `secondWorktree` made.
void removeWorktree(string dir)
{
    import sparkles.build_primitives.git_env : runGit;

    cast(void) runGit(["worktree", "remove", "--force", dir], root);
}

/// Copies fixture `f`, and its line in the root recipe, into worktree `at`.
void copyFixture(ref const Fixture f, string at)
{
    import std.file : copy, dirEntries, SpanMode;

    foreach (e; dirEntries(f.dir, SpanMode.depth))
        if (e.isFile)
        {
            const to = buildPath(at, "libs", f.name, e.name[f.dir.length + 1 .. $]);
            mkdirRecurse(dirName(to));
            copy(e.name, to);
        }
    const recipe = buildPath(at, "dub.sdl");
    write(recipe, withSubPackage(readText(recipe), f.name));
}

// === Oracle 19: the determinism check ===

Verdict[] oracle19()
{
    import sparkles.build_graph.execute : determinismSample;

    Verdict[] vs;
    auto f = Fixture.add("o19", [
        "dub.sdl": recipeOf("o19"),
        "src/sparkles/zz_o19/ok.d": "module sparkles.zz_o19.ok;\n\nint g() { return 1; }\n",
    ]);

    // Step 1: a deterministic compile passes, and the check leaves nothing.
    {
        const cache = freshCache("o19");
        auto published = run(f.name, cache);
        const before = storeEntries(cache);
        RunOptions o;
        o.check = true;
        auto checked = run(f.name, cache, o);
        vs ~= Verdict("step 1",
            published.exitCode != 0 ? "the fixture failed: " ~ published.log.errorLines.join("; ")
            : checked.stats.misses.get("nondeterministic", 0) ? "a deterministic compile was reported nondeterministic"
            : !checked.stats.misses.get("deterministic", 0) ? "nothing was compared"
            : exists(checked.into) ? "the check's private store remains"
            : storeEntries(cache) != before ? "the check published to the shared store" : null,
            text(checked.stats.misses.get("deterministic", 0), " actions compared equal; the private store is gone, "
                ~ "and the shared store holds what it held"));
    }

    // Step 2: a compile that writes the time into its object fails the check.
    {
        const cache = freshCache("o19");
        auto published = run(f.name, cache);
        const compile = taskOf(published, f.task("compile"));
        const key = published.stats.resultKeys.get(compile, null);
        RunOptions o;
        o.check = true;
        // The compiler wrapped below its key: the same declared key, an
        // object that records when it was made.
        o.adjustExecution = (string task, ref ProcessAction pa) {
            if (!task.startsWith(f.task("compile")))
                return;
            string objects;
            foreach (arg; pa.argv)
                if (arg.startsWith("-of="))
                    objects ~= " \"" ~ arg[4 .. $] ~ "\"";
            pa.argv = [sh(), "-c", "\"$0\" \"$@\" && for o in" ~ objects ~ "; do " ~ tool("date")
                ~ " +%s%N >> \"$o\"; done"] ~ pa.argv;
        };
        auto checked = run(f.name, cache, o);
        vs ~= Verdict("step 2",
            !key.length ? "the compile published no result to check"
            : !checked.log.canFind("nondeterministic: result " ~ key) ? "the check did not name the result " ~ key
            : storeHas(cache, key) ? "the differing result is still published" : null,
            "the check failed, naming the result and its object, and removed it");
    }

    // Step 3: a result planted with other bytes fails the check, which
    // executes; with lookup on, the same store hits.
    {
        const cache = freshCache("o19");
        auto published = run(f.name, cache);
        const compile = taskOf(published, f.task("compile"));
        const key = published.stats.resultKeys.get(compile, null);
        const planted = key.length ? plantByte(cache, key) : null;
        auto hit = run(f.name, cache);
        RunOptions o;
        o.check = true;
        auto checked = run(f.name, cache, o);
        vs ~= Verdict("step 3",
            !planted.length ? "no object to plant a byte in"
            : executed(hit, compile) ? "with lookup on, the planted result was not served"
            : !checked.log.canFind("nondeterministic: result " ~ key) ? "the check did not catch the planted bytes" : null,
            "with lookup on, the planted " ~ planted ~ " is served; the check executes and catches it");
    }

    // Step 4: the sample is the same for a commit and its plan, and moves
    // with the commit.
    {
        string[string] keys;
        foreach (i; 0 .. 12)
            keys[text("compile:p", i)] = text("key", i);
        foreach (i; 0 .. 6)
            keys[text("link:p", i)] = text("link-key", i);
        const a = determinismSample(keys, "0123abcd", 4);
        const b = determinismSample(keys, "0123abcd", 4);
        const c = determinismSample(keys, "fedc9876", 4);
        const compiles = a.filter!(t => t.startsWith("compile:")).array.length;
        vs ~= Verdict("step 4",
            a != b ? "one commit sampled two sets"
            : a == c ? "two commits sampled the same set"
            : compiles != 4 || a.length != 8 ? text("the sample took ", compiles, " compiles of ", a.length) : null,
            "four compiles and four other actions, the same for one commit and different for another");
    }
    return vs;
}

/// The result keys the store beneath `cache` holds.
string[] storeEntries(string cache)
{
    import std.file : dirEntries, SpanMode;

    const results = buildPath(cache, "build", "v1", "results");
    if (!exists(results))
        return null;
    string[] keys;
    foreach (e; dirEntries(results, SpanMode.shallow))
        keys ~= e.name[results.length + 1 .. $];
    return keys.sort.release;
}

/// Whether the store beneath `cache` publishes `key`.
bool storeHas(string cache, string key) => exists(buildPath(cache, "build", "v1", "results", key));

/// Plants other bytes under the published result `key`: flips a byte of an
/// object, keeping its size, and records the new bytes' digest as if they
/// had been published so; returns the object's name, or null.
string plantByte(string cache, string key)
{
    import std.file : dirEntries, getAttributes, read, setAttributes, SpanMode;
    import std.string : lineSplitter;
    import sparkles.base.hash.blake3 : blake3;
    import sparkles.build_graph.store : hexOf;

    const entry = buildPath(cache, "build", "v1", "results", key);
    const out_ = buildPath(entry, "out");
    foreach (e; dirEntries(out_, SpanMode.depth))
        if (e.isFile && (e.name.endsWith(".o") || e.name.endsWith(".a")))
        {
            const name = e.name[out_.length + 1 .. $];
            auto bytes = cast(ubyte[]) read(e.name);
            const before = hexOf(blake3(bytes));
            bytes[$ / 2] ^= 0xff;
            setAttributes(e.name, getAttributes(e.name) | octal!200);
            write(e.name, bytes);
            const after = hexOf(blake3(bytes));
            foreach (record; [buildPath(entry, "record"), buildPath(cache, "build", "v1", "records", key)])
                if (exists(record))
                {
                    setAttributes(record, getAttributes(record) | octal!200);
                    write(record, readText(record).replace("output " ~ before ~ " ", "output " ~ after ~ " "));
                }
            return name;
        }
    return null;
}

private bool endsWith(string s, string suffix) => s.length >= suffix.length && s[$ - suffix.length .. $] == suffix;

private enum octal(int n) = (n / 100) * 64 + ((n / 10) % 10) * 8 + n % 10;

// === Oracle 17: the store's lifecycle ===

/// A store of its own beneath `scratch`, with a run directory beside it to
/// publish from, as the executor lays them out.
struct ScratchStore
{
    import sparkles.base.vfs.handles : Dir;
    import sparkles.base.vfs.types : Rights;
    import sparkles.build_graph.store : ResultRecord, Store;
    import sparkles.event_horizon.sys : BlockingVfs;

    alias D = Dir!(BlockingVfs, Rights.all);
    string dir;  /// the cache directory, absolute
    BlockingVfs* vfs;
    D top, build, runOut;
    Store!D store;
    private size_t published;

    @disable this(this);

    static ScratchStore make(string label, uint layout = 1)
    {
        import core.lifetime : move;
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, SymlinkPolicy;

        ScratchStore s;
        s.dir = freshCache(label);
        s.vfs = new BlockingVfs;
        auto top = openRoot!(Rights.all)(s.vfs, s.dir, ambientAuthority(),
            ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
        assert(!top.hasError);
        s.top = move(top.value);
        auto build = s.top.walkAll("build");
        assert(!build.hasError);
        s.build = move(build.value);
        auto runOut = s.top.walkAll("runs/r/out");
        assert(!runOut.hasError);
        s.runOut = move(runOut.value);
        assert(Store!D.open(s.build, "1-1", s.store, layout));
        return s;
    }

    /// Publishes `size` bytes of `fill` as the result `key` of `task`, built
    /// with `toolchain`; returns whether it was published.
    bool publish(string task, string key, size_t size, char fill = 'x', string toolchain = "t1")
    {
        import sparkles.base.hash.blake3 : blake3;
        import sparkles.build_graph.store : OutputRecord;

        const name = text("o", ++published);
        auto out_ = runOut.walkAll(name);
        auto bytes = new char[size];
        bytes[] = fill;
        if (out_.value.writeFileAtomic("f", bytes).hasError)
            return false;
        ResultRecord r;
        r.task = task;
        r.toolchain = toolchain;
        r.declaredKey = "declared-" ~ key;
        r.resultKey = key;
        r.outputs = [OutputRecord("f", size, false, blake3(cast(const(ubyte)[]) bytes))];
        return store.publish(runOut, name, r, "../../../build/v1/results/{}/out") !is null;
    }

    /// Writes a lease on `key` held by `holder`, another process.
    void leaseAs(string key, string holder)
    {
        auto leases = build.walkAll("v1/leases/" ~ key);
        assert(!leases.hasError);
        assert(!leases.value.writeFileAtomic(holder, "").hasError);
    }

    /// The names a directory beneath the layout holds.
    string[] names(string sub)
    {
        import std.file : dirEntries, SpanMode;

        const at = buildPath(dir, "build", "v1", sub);
        if (!exists(at))
            return null;
        string[] result;
        foreach (e; dirEntries(at, SpanMode.shallow))
            result ~= e.name[at.length + 1 .. $];
        return result.sort.release;
    }
}

Verdict[] oracle17()
{
    import std.file : setTimes;
    import std.datetime.systime : SysTime;
    import sparkles.build_graph.store : Manifest, ManifestEntry, cacheDirTag, collectOlderLayouts, resultKey;

    Verdict[] vs;
    bool none(string) => false;

    // Step 1: recency is the leases' order, not the files' access times.
    {
        auto s = ScratchStore.make("o17");
        s.publish("compile:p.a:x", "A", 100);
        s.publish("compile:p.b:x", "B", 100);
        s.store.releaseLeases();
        s.store.lease("A");
        s.store.releaseLeases();
        // An access time pushed far into the past changes nothing.
        const f = buildPath(s.dir, "build", "v1", "results", "A", "out", "f");
        setTimes(f, SysTime(0), SysTime.fromUnixTime(2_000_000_000));
        const report = s.store.evict(150, 1 << 20, &none);
        vs ~= Verdict("step 1", report.evicted != ["B"] ? text("evicted ", report.evicted, ", not B")
            : !s.store.published("A") ? "A, the more recently leased, is gone" : null,
            "B went before A, A's access time notwithstanding");
    }

    // Step 2: publication completes past the bound; eviction stops at 90 %.
    {
        auto s = ScratchStore.make("o17");
        bool all = true;
        foreach (i; 0 .. 10)
            all &= s.publish(text("compile:p.c", i, ":x"), text("C", i), 100);
        s.store.releaseLeases();
        const report = s.store.evict(500, 1 << 20, &none);
        vs ~= Verdict("step 2", !all ? "a publication past the bound did not complete"
            : report.resultBytes > 450 || report.resultBytes + 100 <= 450
                ? text("eviction stopped at ", report.resultBytes, " bytes of a 500-byte bound, not just under 450") : null,
            text("all ten published past the bound; eviction stopped at ", report.resultBytes, " bytes"));
    }

    // Step 3: leases past the bound hold their entries, report the overshoot,
    // and eviction resumes when they end.
    {
        auto s = ScratchStore.make("o17");
        foreach (i; 0 .. 5)
            s.publish(text("compile:p.d", i, ":x"), text("D", i), 100);
        s.store.releaseLeases();
        foreach (i; 0 .. 5)
            s.leaseAs(text("D", i), "99999-1");
        bool other(string h) => h == "99999-1";
        const held = s.store.evict(300, 1 << 20, &other);
        const resumed = s.store.evict(300, 1 << 20, &none);
        vs ~= Verdict("step 3", held.evicted.length ? text("a leased entry was evicted: ", held.evicted)
            : held.leased.length != 5 ? text("the overshoot reported ", held.leased.length, " leased entries, not 5")
            : resumed.resultBytes > 270 ? text("after the leases ended, ", resumed.resultBytes, " bytes remained") : null,
            text("nothing leased went, the five leased were reported, and eviction resumed to ",
                resumed.resultBytes, " bytes"));
    }

    // Step 5: the results' bound takes no record or manifest list; the
    // records' bound takes the lists whose results are gone first.
    {
        auto s = ScratchStore.make("o17");
        Manifest m1, m2;
        m1.files = [ManifestEntry("libs/a.d")];
        m2.files = [ManifestEntry("libs/b.d")];
        const r1 = resultKey("declared-1", m1), r2 = resultKey("declared-2", m2);
        s.publish("compile:p.e:1", r1, 100);
        s.publish("compile:p.e:2", r2, 100);
        s.store.useManifest("declared-1", m1);
        s.store.useManifest("declared-2", m2);
        s.store.releaseLeases();
        const records = s.names("records");
        const lists = s.names("manifests");
        const results = s.store.evict(50, 1 << 20, &none);
        // Eviction adds the evicted results' digest records (BGS5); it may
        // remove none of what was there.
        const kept = records.all!(r => s.names("records").canFind(r)) && s.names("manifests") == lists;
        // r1's result comes back; r2's record goes too, so r2 is neither
        // published nor recorded, and its list must go first.
        s.publish("compile:p.e:1", r1, 100);
        s.store.releaseLeases();
        {
            import std.file : remove;

            remove(buildPath(s.dir, "build", "v1", "records", r2));
        }
        const bound = s.store.recordBytes - 1;
        const dropped = s.store.evict(1 << 20, bound, &none);
        vs ~= Verdict("step 5", results.evicted.length != 2 ? text("the results' bound evicted ", results.evicted)
            : !kept ? "the results' bound took a record or a manifest list"
            : !dropped.recordsDropped ? "the records' bound dropped nothing"
            : s.store.manifests("declared-2").length ? "the list whose result is gone was kept"
            : !s.store.manifests("declared-1").length ? "the list whose result is published went first" : null,
            "the results' bound kept every record and list; the records' bound took the dangling list first");
    }

    // Step 6: removal by key, task, package and toolchain moves exactly the
    // named entries to trash/.
    {
        import sparkles.build_graph.execute : storeOperation;
        import std.array : appender;

        string[] failures;
        foreach (op; [["remove-key=K1", "K1"], ["remove-task=compile:sparkles.p:x", "K1"],
            ["remove-package=sparkles:q", "K3,K4"], ["remove-toolchain=t2", "K2,K4"]])
        {
            auto s = ScratchStore.make("o17");
            s.publish("compile:sparkles.p:x", "K1", 10, 'a', "t1");
            s.publish("compile:sparkles.p:y", "K2", 10, 'b', "t2");
            s.publish("compile:sparkles.q:x", "K3", 10, 'c', "t1");
            s.publish("compile:sparkles.q:y", "K4", 10, 'd', "t2");
            s.store.releaseLeases();
            auto discard = appender!string;
            const status = storeOperation(s.dir, op[0], discard);
            string[] gone;
            foreach (k; ["K1", "K2", "K3", "K4"])
                if (!s.store.published(k))
                    gone ~= k;
            if (status != 0 || gone.join(",") != op[1])
                failures ~= text(op[0], " removed ", gone, ", not ", op[1]);
            else if (s.names("trash").length != gone.length)
                failures ~= text(op[0], " left ", s.names("trash").length, " entries in trash/");
        }
        vs ~= Verdict("step 6", failures.join("; "), "each removal moved exactly the named entries to trash/");
    }

    // Step 7, the store's half: its top directory holds the tag.
    {
        auto s = ScratchStore.make("o17");
        const tag = buildPath(s.dir, "build", "CACHEDIR.TAG");
        vs ~= Verdict("step 7 (store)", !exists(tag) || readText(tag) != cacheDirTag ? "build/CACHEDIR.TAG is missing or other" : null,
            "build/ holds CACHEDIR.TAG with its signature line");
    }

    // Step 8: format versions.
    {
        auto s = ScratchStore.make("o17");
        s.publish("compile:p.f:x", "F", 10);
        s.store.releaseLeases();
        // Another build's layout beside this one.
        {
            import sparkles.build_graph.store : Store;

            typeof(s.store) newer;
            assert(typeof(s.store).open(s.build, "1-1", newer, 2));
        }
        const separate = exists(buildPath(s.dir, "build", "v1")) && exists(buildPath(s.dir, "build", "v2"));
        // An entry in an unknown format: a miss, left in place.
        const record = buildPath(s.dir, "build", "v1", "results", "F", "record");
        write(record, readText(record).replace("format 1\n", "format 99\n"));
        const unknown = s.store.find("F") is null && exists(buildPath(s.dir, "build", "v1", "results", "F"));
        s.store.releaseLeases();
        // The older layout goes only when no lease in it is live.
        s.leaseAs("F", "99999-2");
        bool other(string h) => h == "99999-2";
        const whileLeased = collectOlderLayouts(s.build, &other, 2);
        const afterwards = collectOlderLayouts(s.build, &none, 2);
        vs ~= Verdict("step 8", !separate ? "the two layouts do not have directories of their own"
            : !unknown ? "an entry in an unknown format was served or removed"
            : whileLeased.length ? "the older layout went while a lease in it was live"
            : afterwards != ["v1"] ? text("garbage collection removed ", afterwards, ", not v1") : null,
            "v1 and v2 are separate; an unknown format is a miss left in place; v1 went once its lease ended");
    }

    vs ~= oracle17DigestRecords();
    return vs;
}

/**
Oracle 17 step 4, through the graph: an archive evicted while the link
that consumed it survives is served from its digest record; a new binary
that links it rebuilds it with the record's digests; and a rebuild that
differs is reported nondeterministic, its record taking the new digests.
Step 7's other half: the runs' directory holds the tag.
*/
Verdict[] oracle17DigestRecords()
{
    import sparkles.build_graph.store : cacheDirTag;

    Verdict[] vs;
    auto lib = Fixture.add("o17b", [
        "dub.sdl": recipeOf("o17b"),
        "src/sparkles/zz_o17b/lib.d": "module sparkles.zz_o17b.lib;\n\nint twice(int x) { return 2 * x; }\n",
    ]);
    auto app = Fixture.add("o17a", [
        "dub.sdl": recipeOf("o17a", ["zz-oracle-o17b"]),
        "src/sparkles/zz_o17a/use.d": "module sparkles.zz_o17a.use;\n\nimport sparkles.zz_o17b.lib;\n\n"
            ~ "unittest\n{\n    assert(twice(2) == 4);\n}\n",
    ]);
    const cache = freshCache("o17");
    auto first = run(app.name, cache);
    const archive = taskOf(first, lib.task("compile"));
    const link = taskOf(first, app.task("link"));
    const archiveKey = first.stats.resultKeys.get(archive, null);
    if (first.exitCode != 0 || !archiveKey.length)
        return [Verdict("step 4", "the fixture did not build:" ~ tailOf(first.log))];

    // Evict the archive alone: every other result is leased by a live process.
    {
        auto s = ScratchStoreOver(cache);
        foreach (task, key; first.stats.resultKeys)
            if (key != archiveKey)
                s.leaseAs(key, "99999-3");
        bool other(string h) => h == "99999-3";
        cast(void) s.store.evict(0, 1 << 30, &other);
    }
    auto again = run(app.name, cache);
    vs ~= Verdict("step 4 (link served)",
        executed(again, archive) ? "the archive was rebuilt for a link that hits"
        : executed(again, link) ? "the link did not hit"
        : !again.log.canFind("served from its digest record") ? "the archive was not served from its record" : null,
        "the link hit, and the evicted archive was served from its digest record without rebuilding");

    // A new binary that links it: the archive is rebuilt, matching its record.
    app.put("src/sparkles/zz_o17a/use.d", "module sparkles.zz_o17a.use;\n\nimport sparkles.zz_o17b.lib;\n\n"
        ~ "unittest\n{\n    assert(twice(3) == 6);\n}\n");
    auto rebuilt = run(app.name, cache);
    vs ~= Verdict("step 4 (rebuilt)",
        !executed(rebuilt, archive) ? "the new binary's link did not rebuild the archive"
        : rebuilt.log.canFind("differs from its digest record") ? "the deterministic rebuild was reported different"
        : rebuilt.exitCode != 0 ? "the new binary failed:" ~ tailOf(rebuilt.log) : null,
        "the new binary's link rebuilt the evicted archive, equal to its record");

    // Once more, with an archiver that makes the rebuild differ.
    {
        auto s = ScratchStoreOver(cache);
        foreach (task, key; rebuilt.stats.resultKeys)
            if (key != archiveKey)
                s.leaseAs(key, "99999-4");
        bool other(string h) => h == "99999-4";
        cast(void) s.store.evict(0, 1 << 30, &other);
    }
    app.put("src/sparkles/zz_o17a/use.d", "module sparkles.zz_o17a.use;\n\nimport sparkles.zz_o17b.lib;\n\n"
        ~ "unittest\n{\n    assert(twice(4) == 8);\n}\n");
    RunOptions o;
    o.adjustExecution = (string task, ref ProcessAction pa) {
        if (task != archive)
            return;
        string objects;
        foreach (arg; pa.argv)
            if (arg.startsWith("-of="))
                objects ~= " \"" ~ arg[4 .. $] ~ "\"";
        pa.argv = [sh(), "-c", "\"$0\" \"$@\" && for o in" ~ objects ~ "; do printf x >> \"$o\"; done"] ~ pa.argv;
    };
    auto differing = run(app.name, cache, o);
    vs ~= Verdict("step 4 (differs)",
        !executed(differing, archive) ? "the archive was not rebuilt"
        : !differing.log.canFind("differs from its digest record") ? "a rebuild unlike its record was not reported" : null,
        "a rebuild unlike its record was reported nondeterministic");

    const runsTag = buildPath(cache, "runs", "CACHEDIR.TAG");
    vs ~= Verdict("step 7 (runs)", !exists(runsTag) || readText(runsTag) != cacheDirTag
        ? "runs/CACHEDIR.TAG is missing or other" : null, "runs/ holds CACHEDIR.TAG with its signature line");
    return vs;
}

/// A store a run already made, opened beside it.
ScratchStore ScratchStoreOver(string cache)
{
    import core.lifetime : move;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;

    ScratchStore s;
    s.dir = cache;
    s.vfs = new BlockingVfs;
    auto top = openRoot!(Rights.all)(s.vfs, cache, ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
    assert(!top.hasError);
    s.top = move(top.value);
    auto build = s.top.walkAll("build");
    s.build = move(build.value);
    auto runOut = s.top.walkAll("runs/r/out");
    s.runOut = move(runOut.value);
    assert(typeof(s.store).open(s.build, "1-1", s.store));
    return s;
}

// === Oracle 18: miss explanations ===

/// `ci cache store explain <task>`'s lines against the store beneath `cache`.
string explained(string cache, string task)
{
    import std.array : appender;

    auto w = appender!string;
    cast(void) explainTask(root, cache, task, w);
    return w.data;
}

/// The class and detail of `task`'s miss in `g`'s log: `declared: differs in …`.
string missOf(ref const GraphRun g, string task)
{
    import std.string : indexOf, lineSplitter;

    foreach (line; g.log.lineSplitter)
        if (line.startsWith("[" ~ task ~ " stderr] miss ("))
        {
            const rest = line[line.indexOf("miss (") + 6 .. $];
            const close = rest.indexOf("): ");
            return (rest[0 .. close] ~ ": " ~ rest[close + 3 .. $]).idup;
        }
    return null;
}

Verdict[] oracle18()
{
    import std.digest.sha : sha256Of;
    import std.file : dirEntries, read, remove, SpanMode;
    import sparkles.build_graph.execute : storeOperation;
    import sparkles.build_graph.store : hexOf;
    import std.array : appender;

    Verdict[] vs;
    // The compile of `o18` reads `o18b`'s module through its import path, a
    // file its manifest lists but its declared key does not; and it probes
    // for a module `o18b` does not have, an absent candidate.
    enum libModule = "module sparkles.zz_o18b.lib;\n\nint g() { return 2; }\n";
    auto dep = Fixture.add("o18b", [
        "dub.sdl": recipeOf("o18b"),
        "src/sparkles/zz_o18b/lib.d": libModule,
    ]);
    auto fx = Fixture.add("o18", [
        "dub.sdl": recipeOf("o18", ["zz-oracle-o18b"]),
        "src/sparkles/zz_o18/m.d": "module sparkles.zz_o18.m;\n\nimport sparkles.zz_o18b.lib;\n\n"
            ~ "static if (__traits(compiles, { import sparkles.zz_o18b.missing; }))\n    enum hasMissing = true;\n"
            ~ "else\n    enum hasMissing = false;\n\nint f() { return g(); }\n",
    ]);
    const cache = freshCache("o18");
    auto first = run(fx.name, cache);
    const compile = taskOf(first, fx.task("compile"));
    if (first.exitCode != 0)
        return [Verdict("setup", "the fixture failed:" ~ tailOf(first.log))];

    // Each miss in a run, classified and naming what changed; explain says
    // the same and executes nothing. Afterwards the baseline is published
    // again, so the next scenario's preimage is compared with it alone.
    void scenario(string what, string class_, string names, void delegate() change, void delegate() undo,
        RunOptions o = RunOptions.init)
    {
        change();
        const before = storeEntries(cache);
        const lines = explained(cache, compile);
        const executedNothing = storeEntries(cache) == before;
        auto g = run(fx.name, cache, o);
        undo();
        cast(void) run(fx.name, cache);
        const miss = missOf(g, compile);
        string why;
        if (!miss.startsWith(class_ ~ ": "))
            why = text("the run classed it `", miss, "`, not ", class_);
        else if (!miss.canFind(names))
            why = text("the run's explanation `", miss, "` does not name ", names);
        else if (class_ == "declared" && miss.canFind(", "))
            why = text("the run's explanation `", miss, "` names more than the substituted component");
        else if (o.adjustTools is null && !lines.canFind(compile ~ ": miss (" ~ class_ ~ "): "))
            why = text("explain did not class it ", class_, ":\n", lines);
        else if (!executedNothing)
            why = "explain changed the store";
        vs ~= Verdict(what, why, text("`", miss, "`", o.adjustTools is null
            ? ", in the run and from explain, which executed nothing" : ""));
    }

    // Declared: one more argument, and nothing else. (A recipe's version
    // would be another variant, so another task.)
    {
        RunOptions o;
        o.adjustPlan = (ref Planned p) {
            wrapActions(p, compile, (string[] argv) => argv ~ "-d-version=ZzOracle18");
        };
        o.adjustTools = (ref Tools) {}; // explain plans afresh, and cannot see it
        scenario("declared (argument)", "declared", "arg", () {}, () {}, o);
    }
    // Manifest: a file the manifest lists, not the declared key, edited.
    scenario("manifest (edited)", "manifest", "libs/zz-oracle-o18b/src/sparkles/zz_o18b/lib.d changed",
        () => dep.put("src/sparkles/zz_o18b/lib.d", libModule ~ "// edited\n"),
        () => dep.put("src/sparkles/zz_o18b/lib.d", libModule));
    // Manifest: a file created at an absent candidate.
    scenario("manifest (absent candidate)", "manifest", "missing.d appeared",
        () => dep.put("src/sparkles/zz_o18b/missing.d", "module sparkles.zz_o18b.missing;\n"),
        () => remove(buildPath(dep.dir, "src/sparkles/zz_o18b/missing.d")));
    // Declared: the toolchain, another compiler build in its place.
    {
        RunOptions o;
        o.adjustTools = (ref Tools t) {
            import std.file : setAttributes;

            const wrapper = buildPath(scratch, "ldc2-wrapped");
            write(wrapper, "#!" ~ sh() ~ "\nexec " ~ t.compiler ~ " \"$@\"\n");
            setAttributes(wrapper, octal!755);
            t.compiler = wrapper;
        };
        // The wrapper's path is in the compile's arguments too, so the
        // explanation names both; nothing else may differ.
        auto g = run(fx.name, cache, o);
        cast(void) run(fx.name, cache);
        const miss = missOf(g, compile);
        const named = miss.startsWith("declared: differs in ") ? miss["declared: differs in ".length .. $] : null;
        vs ~= Verdict("declared (compiler)", named.split(", ").sort.release != ["arg", "toolchain"]
            ? text("another compiler build classed `", miss, "`") : null,
            "`" ~ miss ~ "`: the toolchain, and the argument that names the compiler");
    }
    // Evicted: the result and its record gone, the manifest still matching.
    {
        auto again = run(fx.name, cache);
        const key = again.stats.resultKeys.get(compile, null);
        auto discard = appender!string;
        cast(void) storeOperation(cache, "remove-key=" ~ key, discard);
        cast(void) storeOperation(cache, "gc", discard);
        const recorded = buildPath(cache, "build", "v1", "records", key);
        if (exists(recorded))
            remove(recorded);
        const lines = explained(cache, compile);
        auto g = run(fx.name, cache);
        const miss = missOf(g, compile);
        vs ~= Verdict("evicted", !miss.startsWith("evicted: ") ? text("the run classed it `", miss, "`")
            : !lines.canFind(compile ~ ": miss (evicted): ") ? "explain did not class it evicted:\n" ~ lines : null,
            "`" ~ miss ~ "`, in the run and from explain");
    }

    // A redacted value is in the store only as a keyed digest.
    {
        import sparkles.build_graph.actions : Action, DeclaredOutput;
        import sparkles.build_primitives.task.action : EnvEntry, TaskAction;
        import sparkles.build_primitives.task.model : taskId;

        enum secret = "oracle-18-secret-hunter2";
        RunOptions o;
        o.adjustPlan = (ref Planned p) {
            p.graph.actions ~= Action(ActionKind.generate, taskId("generate", "oracle-18", "secret", "ldc", "0").value,
                0, TaskAction(ProcessAction(argv: [tool("true")],
                    envDelta: [EnvEntry("PATH", ""), EnvEntry("ORACLE_18_TOKEN", secret, redacted: true)])),
                [DeclaredOutput(".", true)], 1);
        };
        auto g = run(fx.name, cache, o);
        const plainDigest = hexOf(sha256Of(secret));
        string found;
        foreach (e; dirEntries(buildPath(cache, "build"), SpanMode.depth))
            if (e.isFile)
            {
                const bytes = cast(const(char)[]) read(e.name);
                if (bytes.canFind(secret) || bytes.canFind(plainDigest))
                    found = e.name;
            }
        string preimages;
        foreach (e; dirEntries(buildPath(cache, "build", "v1", "preimages"), SpanMode.shallow))
            preimages ~= readText(e.name);
        vs ~= Verdict("redacted value", g.exitCode != 0 ? "the run failed:" ~ tailOf(g.log)
            : found.length ? "the value, or its plain SHA-256, is in " ~ found
            : !preimages.canFind("ORACLE_18_TOKEN=redacted:") ? "no preimage records the redacted entry" : null,
            "the preimage holds the value only as a keyed digest; neither it nor its SHA-256 is in the store");
    }
    return vs;
}

// === Oracle 24, steps 5 and 6: the store's links, and file identity ===

Verdict[] oracle24()
{
    import std.file : dirEntries, getTimes, remove, setTimes, SpanMode, symlink;
    import std.process : execute;
    import std.datetime.systime : SysTime;
    import std.array : appender;

    Verdict[] vs;
    auto fx = Fixture.add("o24", [
        "dub.sdl": recipeOf("o24"),
        "src/sparkles/zz_o24/a.d": "module sparkles.zz_o24.a;\n\nint a() { return 1; }\n",
        "src/sparkles/zz_o24/b.d": "module sparkles.zz_o24.b;\n\nint b() { return 2; }\n",
    ]);

    // Step 5: a link planted in a published result is a corrupt entry, found
    // without touching what it points to.
    {
        const cache = freshCache("o24");
        auto g = run(fx.name, cache);
        const compile = taskOf(g, fx.task("compile"));
        const key = g.stats.resultKeys.get(compile, null);
        string planted;
        const out_ = buildPath(cache, "build", "v1", "results", key, "out");
        foreach (e; dirEntries(out_, SpanMode.shallow))
            if (e.isFile && e.name.endsWith(".o"))
                planted = e.name;
        const target = buildPath(scratch, "o24-link-target.o");
        if (planted.length)
        {
            import std.file : copy;

            copy(planted, target);
            remove(planted);
            symlink(target, planted);
        }
        const traceFile = buildPath(scratch, "o24.trace");
        const ci = buildPath(root, "apps", "ci", "build", "ci");
        // explain reads the store beneath $XDG_CACHE_HOME/sparkles: point it here.
        const xdg = buildPath(scratch, "o24-xdg");
        mkdirRecurse(xdg);
        if (!exists(buildPath(xdg, "sparkles")))
            symlink(cache, buildPath(xdg, "sparkles"));
        const r = execute(["strace", "-f", "-qq", "-e", "trace=%file", "-o", traceFile, ci, "cache", "store",
            "explain", compile], ["XDG_CACHE_HOME": xdg]);
        const trace = exists(traceFile) ? readText(traceFile) : "";
        vs ~= Verdict("step 5", !planted.length ? "no object to plant a link at"
            : !r.output.canFind("miss") ? "the lookup through a planted link did not miss:\n" ~ r.output
            : !exists(buildPath(cache, "build", "v1", "trash")) || storeHas(cache, key) ? "the entry was not moved to trash/"
            : trace.canFind(target) ? "the lookup touched the link's target " ~ target : null,
            "the lookup refused the planted link, moved the entry to trash/, and never touched its target");
    }

    // Step 6: a file replaced by a hard link to another of the same size
    // and modification time is rehashed.
    {
        import std.file : rename;
        import core.sys.posix.unistd : link;
        import std.string : toStringz;

        const cache = freshCache("o24");
        auto g = run(fx.name, cache);
        const compile = taskOf(g, fx.task("compile"));
        const a = buildPath(fx.dir, "src/sparkles/zz_o24/a.d");
        const b = buildPath(fx.dir, "src/sparkles/zz_o24/b.d");
        // b, renamed to the same size as a with other bytes, then linked in a's place.
        fx.put("src/sparkles/zz_o24/b.d", "module sparkles.zz_o24.a;\n\nint a() { return 9; }\n");
        SysTime atime, mtime;
        getTimes(a, atime, mtime);
        setTimes(b, atime, mtime);
        remove(a);
        const linked = link(b.toStringz, a.toStringz) == 0;
        const lines = explained(cache, compile);
        // The first action that reads it (the test-root module's generator,
        // then the compile) must miss naming it.
        vs ~= Verdict("step 6", !linked ? "cannot hard-link the fixture"
            : !lines.canFind(": miss (") || !lines.canFind("zz_o24/a.d")
                ? "a file of another identity, its size and time the same, was trusted:\n" ~ lines : null,
            "the hard link, same size and time, was rehashed and missed");
    }
    return vs;
}

// === Oracle 10: generators ===

/// An edit to a tracked file, undone when it goes.
struct Edited
{
    string path;
    private string before;

    @disable this(this);

    static Edited append(string relative, string more)
    {
        Edited e;
        e.path = buildPath(root, relative);
        e.before = readText(e.path);
        write(e.path, e.before ~ more);
        return e;
    }

    ~this()
    {
        if (path.length)
            write(path, before);
    }
}

/// The plan's process action whose argument vector has `arg`, by id, or null.
string actionWithArgument(ref const GraphRun g, string prefix, string arg)
{
    foreach (ref a; g.plan.graph.actions)
        if (a.id.text.startsWith(prefix))
        {
            bool has;
            a.action.match!((ref const ProcessAction p) { has = p.argv.canFind(arg); }, (ref const _) {});
            if (has)
                return a.id.text;
        }
    return null;
}

/// The argument vector of `task` in `g`'s plan.
const(string)[] argvOf(ref const GraphRun g, string task)
{
    foreach (ref a; g.plan.graph.actions)
        if (a.id.text == task)
            return a.action.match!((ref const ProcessAction p) => p.argv, (ref const _) => cast(const(string)[]) null);
    return null;
}

Verdict[] oracle10()
{
    Verdict[] vs;
    const cache = freshCache("o10");
    auto base = run("ui-raylib", cache);
    const gen = actionWithArgument(base, "generate:shader-compile:generator:", "--package=libs/ui");
    if (base.exitCode != 0 || !gen.length)
        return [Verdict("setup", "ui-raylib did not build:" ~ tailOf(base.log))];
    // The compiles that read its outputs.
    string[] consumers;
    foreach (ref a; base.plan.graph.actions)
        if (a.kind == ActionKind.compile && argvOf(base, a.id.text).canFind!(x => x.canFind("$IN(" ~ gen ~ ")")))
            consumers ~= a.id.text;

    // Step 3: no staleness flag, and no dub.
    {
        const argv = argvOf(base, gen);
        vs ~= Verdict("step 3", argv.canFind("--if-stale") ? "the generator is invoked with --if-stale"
            : argv.canFind!(x => x.canFind("dub")) ? "the generator's invocation names dub: " ~ argv.join(" ") : null,
            "the shader compiler runs without --if-stale, and nothing names dub");
    }

    // Step 2: stale files in the in-tree directory are not read.
    {
        import std.file : remove;

        const stale = buildPath(root, "libs/ui/generated/shaders/zz-oracle-10-stale.frag");
        write(stale, "this is not GLSL\n");
        scope (exit)
            remove(stale);
        bool inTree;
        foreach (c; consumers)
            inTree |= argvOf(base, c).canFind!(x => x.startsWith("-J=") && x.canFind("generated/shaders"));
        auto g = run("ui-raylib", cache);
        vs ~= Verdict("step 2", !consumers.length ? "no compile reads the generator's outputs"
            : inTree ? "a compile string-imports the in-tree generated directory"
            : g.exitCode != 0 ? "a run with stale in-tree files failed:" ~ tailOf(g.log) : null,
            text(consumers.length, " compiles read the generator's outputs, none the in-tree directory with its stale file"));
    }

    // Step 1: a shader edit reruns the generator and its consumers, and no
    // other compile.
    {
        auto edit = Edited.append("libs/ui/shaders/effects.d", "\n/// oracle 10\n"
            ~ "@fragment vec4 zzOracle10(@input vec2 fragTexCoord, @input vec4 fragColor,\n"
            ~ "    Sampler2D texture0, @uniform vec2 uExtentCells)\n    => fragColor;\n");
        auto g = run("ui-raylib", cache);
        string[] others;
        foreach (t; g.stats.executedTasks)
            if (t.startsWith("compile:") && !consumers.canFind(t))
                others ~= t;
        string[] missed;
        foreach (c; consumers)
            if (!executed(g, c))
                missed ~= c;
        vs ~= Verdict("step 1", g.exitCode != 0 ? "the edited shader failed:" ~ tailOf(g.log)
            : !executed(g, gen) ? "the generator did not rerun"
            : missed.length ? text("its consumers did not rerun: ", missed)
            : others.length ? text("other compiles reran: ", others) : null,
            text("the generator and its ", consumers.length, " consumers reran, and no other compile"));
    }
    cast(void) run("ui-raylib", cache); // the tree as it is, published again

    // Step 4: an edit to a module the shaders import reruns the generator;
    // one to a module they do not import does not.
    {
        auto g = () {
            auto edit = Edited.append("libs/shaders/src/sparkles/shaders/math.d", "\n// oracle 10\n");
            return run("ui-raylib", cache);
        }();
        auto h = () {
            auto edit = Edited.append("libs/ui/src/sparkles/ui/css.d", "\n// oracle 10\n");
            return run("ui-raylib", cache);
        }();
        vs ~= Verdict("step 4", !executed(g, gen) ? "an edit to an imported module left the generator a hit"
            : executed(h, gen) ? "an edit to a module the shaders do not import reran the generator" : null,
            "an imported module's edit reran the generator; another module's did not");
    }
    return vs;
}
