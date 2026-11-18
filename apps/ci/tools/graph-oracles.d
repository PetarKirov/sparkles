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
import std.algorithm : canFind, filter, map, sort, startsWith;
import std.array : array, join, replace;
import std.conv : text;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.process : thisProcessID;
import std.stdio : stderr, writeln;
import std.sumtype : match;

import sparkles.build_graph.actions : ActionKind;
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
    Oracle("11", &oracle11),
    Oracle("13", &oracle13),
    Oracle("16", &oracle16),
    Oracle("19", &oracle19),
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
    string task(string kind) const => kind ~ ":sparkles." ~ name;
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
`cImportPaths` its C include roots. Written from the `dub.sdl` schema
(SDE9), as no recipe here is written as text.
*/
string recipeOf(string name, string[] dependencies = null, string[] cImportPaths = null)
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
