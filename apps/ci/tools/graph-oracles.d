#!/usr/bin/env dub
/+ dub.sdl:
    name "graph_oracles"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:build-graph" path="../../.."
    dependency "sparkles:unittest-layout" path="../../.."
    dependency "sparkles:d-source" path="../../.."
    dependency "sparkles:test-runner-core" path="../../.."
    // The driver the oracles run the graph through, and ci's statement of
    // the workspace inputs it plans against.
    dflags "-I=$PACKAGE_DIR/../src" "-i=repository_inputs" "-i=graph_driver" "-i=test_leg" platform="ldc"

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

`--only=16` runs one oracle's steps; without it every oracle runs but the
hours-long ones (`2-all`, `21-replay`), which run only when named. The
scratch stores live beneath `ORACLE_SCRATCH` (the temporary directory by
default), which oracle 4 needs on the worktree's file system; oracle 7's
second worktree goes beneath the temporary directory, on another. Needs
the dev shell: its toolchain, `SPARKLES_DUB_SOURCES` and `strace`. A check
that is interrupted can leave a fixture behind; the next run removes it.
*/
module graph_oracles;

import core.time : msecs, seconds;
import std.algorithm : all, any, canFind, count, filter, map, sort, startsWith;
import std.array : array, join, replace, split;
import std.conv : text, to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.process : thisProcessID;
static import std.process;
static import std.algorithm;
static import std.file;
import std.stdio : stderr, writeln;
import std.string : indexOf, lineSplitter;
static import core.time;
static import std.stdio;
import std.sumtype : match;

import sparkles.build_graph.actions : ActionKind, Tools;
import sparkles.build_primitives.task.action : ProcessAction;
import sparkles.build_primitives.dub_manifest : DubManifest, DubPlatformValues;

import graph_driver;

/// The worktree the oracles run in, absolute.
__gshared string root;
/// The scratch directory every oracle's stores lie beneath.
__gshared string scratch;

int main(string[] args)
{
    // Oracle 7's builders: copies of this program sharing one store.
    if (args.canFind!(a => a.startsWith("--child=")))
        return childBuild(args);
    const only = args.filter!(a => a.startsWith("--only=")).map!(a => a["--only=".length .. $]).array;
    const positional = args[1 .. $].filter!(a => !a.startsWith("--")).array;
    root = buildNormalizedPath(absolutePath(positional.length ? positional[0] : "."));
    scratch = buildPath(std.process.environment.get("ORACLE_SCRATCH", tempDir), text("graph-oracles-", thisProcessID));
    mkdirRecurse(scratch);
    scope (exit)
        if (exists(scratch))
            rmdirRecurse(scratch);
    removeStaleFixtures();

    bool ok = true;
    size_t ran;
    foreach (ref o; oracles)
    {
        // An `-all` or `-replay` oracle runs for hours: only when named.
        if (only.length ? !only.canFind(o.id) : std.algorithm.endsWith(o.id, "-all", "-replay") != 0)
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
    Oracle("2", &oracle2),
    Oracle("2-all", &oracle2All),
    Oracle("3", &oracle3),
    Oracle("4", &oracle4),
    Oracle("5", &oracle5),
    Oracle("7", &oracle7),
    Oracle("8", &oracle8),
    Oracle("9", &oracle9),
    Oracle("10", &oracle10),
    Oracle("11", &oracle11),
    Oracle("13", &oracle13),
    Oracle("16", &oracle16),
    Oracle("17", &oracle17),
    Oracle("18", &oracle18),
    Oracle("19", &oracle19),
    Oracle("21", &oracle21),
    Oracle("21-replay", &oracle21Replay),
    Oracle("24", &oracle24),
    Oracle("cic11", &oracleCic11),
    Oracle("m8", &oracleM8),
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
string recipeOf(string name, string[] dependencies = null, string[] cImportPaths = null, string[] versions = null,
    void delegate(ref DubManifest) tweak = null)
{
    import sparkles.build_primitives.dub_manifest : DubConfiguration, DubDependency;
    import sparkles.wired.sdl : toSDL;

    alias values = platformValues;
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
    if (tweak !is null)
        tweak(m);
    const sdl = toSDL(m);
    assert(sdl.hasValue, sdl.error.toString);
    return sdl.value[].idup;
}

/// A list-valued setting of the schema: `values`, on every platform.
DubPlatformValues platformValues(string[] v...)
{
    DubPlatformValues p;
    p.values = v.dup;
    return p;
}

/// The recipe `text`, decoded through the `dub.sdl` schema.
DubManifest decodeRecipe(string text)
{
    import sparkles.build_primitives.dub_manifest : decodeDubManifestLenient;
    import sparkles.wired.sdl : parseSdlDocument, sdlDubRecipe;

    auto parsed = parseSdlDocument!sdlDubRecipe(text);
    assert(parsed.hasValue, parsed.error.toString);
    auto decoded = decodeDubManifestLenient(parsed.document);
    assert(decoded.hasValue, decoded.error.toString);
    return cast() decoded.value;
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
    Verdict[] vs = [Verdict("step 2",
        !executed(first, test) || !executed(second, test) ? "the test did not run on the second request"
        : executed(second, compile) ? "the second request recompiled" : null,
        "the test ran on both requests, its compile reused on the second")];

    // Step 1 with D62: a test that declares `dub` runs the real one; one that
    // does not meets the trap, which records its call.
    enum callsDub = "import std.process : execute;\n\n"
        ~ "@(\"o11.dub\") unittest\n{\n    const r = execute([\"dub\", \"--version\"]);\n    assert(r.status == 0, r.output);\n}\n";
    enum declaration = "{\n  \"tools\": [{ \"name\": \"dub\", \"reason\": \"oracle 11\" }]\n}\n";
    auto declared = Fixture.add("o11d", [
        "dub.sdl": recipeOf("o11d"),
        "test-programs.json": declaration,
        "src/sparkles/zz_o11d/d.d": "module sparkles.zz_o11d.d;\n\n" ~ callsDub,
    ]);
    auto undeclared = Fixture.add("o11u", [
        "dub.sdl": recipeOf("o11u"),
        "src/sparkles/zz_o11u/u.d": "module sparkles.zz_o11u.u;\n\n" ~ callsDub,
    ]);
    auto withDub = run(declared.name, freshCache("o11"));
    auto trapped = run(undeclared.name, freshCache("o11"));
    vs ~= Verdict("step 1, a declared dub (D62)", withDub.exitCode != 0 ? "the declaring test did not run dub:" ~ tailOf(withDub.log)
        : withDub.dubCalls.length ? "the declaring test met the trap: " ~ withDub.dubCalls
        : trapped.exitCode == 0 ? "a test that declares no dub ran it"
        : !trapped.dubCalls.canFind("--version") ? "the trap did not record the undeclared call: " ~ trapped.dubCalls : null,
        "a test that declares dub ran the real one; one that does not met the trap, which recorded its call");
    declared.put("test-programs.json", "{\n  \"tools\": [{ \"name\": \"make\", \"reason\": \"oracle 11\" }]\n}\n");
    auto refused = run(declared.name, freshCache("o11"));
    vs ~= Verdict("step 1, another tool", !refused.error.canFind("D62") ? "a declared tool other than dub was accepted: " ~ refused.error : null,
        "a declared tool other than dub fails planning, naming D62");
    return vs;
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

    // Step 5: publication fails three ways; each run's outcome must equal a
    // run whose publication succeeded, and each failure must be reported.
    {
        import core.sys.posix.unistd : getgid, getuid;
        import std.file : setAttributes;
        import sparkles.build_graph.store : beforePublication;

        auto p = Fixture.add("o16p", [
            "dub.sdl": recipeOf("o16p"),
            "src/sparkles/zz_o16p/p.d": "module sparkles.zz_o16p.p;\n\nunittest\n{\n    assert(1 + 1 == 2);\n}\n",
        ]);
        string why(int exitCode, const string[] executedTasks, string log, int normalExit, const string[] normalTasks,
            string failure)
        {
            return exitCode != normalExit ? text("the run exited ", exitCode, ", a run that published ", normalExit)
                : executedTasks.dup.sort.release != normalTasks.dup.sort.release ? text("it ran ", executedTasks,
                    ", a run that published ", normalTasks)
                : !log.canFind(failure) ? "the failure was not reported:" ~ tailOf(log) : null;
        }

        // A full file system: a builder whose cache is a small tmpfs of its
        // own (in a user namespace), filled at its last publication.
        {
            const compile = p.task("compile");
            string[] tmpfs(string cache) => [tool("unshare"), "-rm", sh(), "-c",
                "mount -t tmpfs -o size=512m tmpfs \"$0\" && exec " ~ tool("unshare") ~ " --user --map-user="
                ~ text(getuid()) ~ " --map-group=" ~ text(getgid()) ~ " \"$@\"", cache];
            const c1 = freshCache("o16"), c2 = freshCache("o16");
            auto normal = startChild(p.name, c1, ["--task=" ~ compile], tmpfs(c1)).wait();
            auto full = startChild(p.name, c2, ["--task=" ~ compile, "--fill-after=" ~ compile],
                tmpfs(c2)).wait();
            const task = normal.resultKeys.byKey.filter!(t => t.startsWith(compile)).array;
            vs ~= Verdict("step 5, a full file system", normal.exitCode != 0 ? "the builder failed on its tmpfs:" ~ tailOf(normal.log ~ normal.raw)
                : !task.length ? "the compile published nothing on the tmpfs"
                : (task[0] in full.resultKeys) !is null ? "the compile published on a full file system"
                : why(full.exitCode, full.executed, full.log, normal.exitCode, normal.executed, "cannot "),
                "with the store's file system full once the compile ended, the run succeeded as one that "
                ~ "published, and reported the failed publication");
        }

        // A read-only results/.
        {
            const normalCache = freshCache("o16"), cache = freshCache("o16");
            auto normal = run(p.name, normalCache);
            const results = buildPath(cache, "build", "v1", "results");
            mkdirRecurse(results);
            setAttributes(results, octal!555);
            auto ro = run(p.name, cache);
            setAttributes(results, octal!755);
            vs ~= Verdict("step 5, a read-only results/", ro.stats.resultKeys.byKey.any!(t => storeDir(cache, "results")
                    .canFind(ro.stats.resultKeys[t])) ? "a result was published into a read-only results/"
                : why(ro.exitCode, ro.stats.executedTasks, ro.log, normal.exitCode, normal.stats.executedTasks, "cannot publish"),
                "with results/ read-only, the run succeeded as one that published, and reported each failed publication");
        }

        // A rename that fails: a file planted where the entry would go.
        {
            const normalCache = freshCache("o16"), cache = freshCache("o16");
            auto normal = run(p.name, normalCache);
            renameBlockCache = cache;
            beforePublication = &blockRename;
            auto blocked = run(p.name, cache);
            beforePublication = null;
            vs ~= Verdict("step 5, a rename that fails",
                why(blocked.exitCode, blocked.stats.executedTasks, blocked.log, normal.exitCode, normal.stats.executedTasks,
                    "cannot publish the entry"),
                "with every publishing rename failing, the run succeeded as one that published, and reported each");
        }
    }
    vs ~= Verdict("step 6", "not run: needs a virtual machine whose power is cut between a rename and the next write", null);
    return vs;
}

/// A git worktree of the repository at `HEAD`, beneath `scratch`.
string secondWorktree(string under = scratch)
{
    import sparkles.build_primitives.git_env : runGit;

    const dir = buildPath(under, text("worktree-", thisProcessID));
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
            : checked.exitCode == 0 ? "the check exited zero over a difference (CIC13)"
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

/// `ci cache explain <task>`'s lines against the store beneath `cache`.
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

// === ci task-DAG M7b's gate: the runner core and fail-fast ===

/**
CIC11: a binary run through ci's runner core and run standalone agree on
every test's verdict, and on the run's. Fail-fast ends another package's
leg with its whole process tree, nested children included (TDE1, TDE2).
*/
Verdict[] oracleCic11()
{
    import core.sys.posix.signal : kill;
    import std.datetime.stopwatch : AutoStart, StopWatch;
    import std.file : dirEntries, SpanMode;
    import std.algorithm.iteration : uniq;
    import std.regex : matchAll, regex;
    import std.string : lineSplitter, strip;
    import sparkles.build_graph.actions : TestLeg;

    Verdict[] vs;
    // The verdict each test got, `✓ name`, from a transcript.
    static string[] verdicts(string transcript)
    {
        string[] found;
        foreach (m; transcript.matchAll(regex(`([✓✗⊘]) (?:\S+ )?(cic11\.\w+)`)))
            found ~= m[1] ~ " " ~ m[2];
        return found.sort.uniq.array;
    }

    // Step 1: every kind of test, through the core and standalone.
    {
        auto f = Fixture.add("cic11", [
            "dub.sdl": recipeOf("cic11", ["test-attributes"]),
            "src/sparkles/zz_cic11/t.d": "module sparkles.zz_cic11.t;\n\n"
                ~ "import sparkles.test_runner.attributes : serial, ThreadAffinity;\n\n"
                ~ "@(\"cic11.passes\") unittest { assert(1 + 1 == 2); }\n"
                ~ "@(\"cic11.fails\") unittest { assert(false, \"planted\"); }\n"
                ~ "@(\"cic11.skips\") unittest\n{\n    import sparkles.test_runner.skip : skipTest;\n\n"
                ~ "    return skipTest(\"planted\");\n}\n"
                ~ "@(\"cic11.serial\") @serial unittest {}\n"
                ~ "@(\"cic11.mainThread\") @serial(threadAffinity: ThreadAffinity.mainThread) unittest {}\n"
                ~ "static foreach (i; 0 .. 12)\n    mixin(`@(\"cic11.many` ~ i.stringof ~ `\") unittest {}`);\n",
        ]);
        RunOptions o;
        o.runnerCore = true;
        o.legs = [TestLeg(4, true, "parallel")];
        auto core = run(f.name, freshCache("cic11"), o);
        string binary;
        if (exists(buildPath(core.into, "out", "link")))
            foreach (e; dirEntries(buildPath(core.into, "out", "link"), SpanMode.depth))
                if (e.isFile && e.name.canFind(f.name) && e.name.canFind("-test-"))
                    binary = e.name;
        auto standalone = binary.length ? std.process.execute([binary, "--skip-slow", "-t", "4"], null,
            std.process.Config.none, size_t.max, root) : typeof(std.process.execute([""]))(-1, "no binary");
        const a = verdicts(core.log), b = verdicts(standalone.output);
        vs ~= Verdict("step 1",
            core.error.length ? core.error
            : a.length != 17 ? text("the core reported ", a.length, " verdicts, not 17: ", a)
            : a != b ? text("the core and the standalone runner disagree:\n  core:       ", a, "\n  standalone: ", b)
            : (core.exitCode == 0) != (standalone.status == 0) ? text("the runs' statuses disagree: core ",
                core.exitCode, ", standalone ", standalone.status)
            : core.exitCode == 0 ? "a failing test passed the leg" : null,
            text("through the core and standalone, all ", a.length, " tests got the same verdict (",
                a.count!(v => v.startsWith("✗")), " failed, ", a.count!(v => v.startsWith("⊘")),
                " skipped), and both runs failed"));
    }

    // Step 2: fail-fast ends a leg whose test holds a nested process tree.
    {
        const pids = buildPath(scratch, "cic11-pids");
        if (exists(pids))
            std.file.remove(pids);
        auto holder = Fixture.add("cic11h", [
            "dub.sdl": recipeOf("cic11h"),
            "src/sparkles/zz_cic11h/t.d": "module sparkles.zz_cic11h.t;\n\n"
                ~ "@(\"cic11h.holds\") unittest\n{\n    import std.process : executeShell;\n\n"
                ~ "    // A grandchild and a great-grandchild, each recording its pid.\n"
                ~ "    executeShell(`sh -c 'sleep 300 & echo $! >> " ~ pids ~ "; sleep 300 & echo $! >> " ~ pids
                ~ "; wait' & echo $! >> " ~ pids ~ "; wait`);\n}\n",
        ]);
        auto failer = Fixture.add("cic11f", [
            "dub.sdl": recipeOf("cic11f"),
            "src/sparkles/zz_cic11f/t.d": "module sparkles.zz_cic11f.t;\n\n"
                ~ "@(\"cic11f.fails\") unittest\n{\n    import core.thread : Thread;\n    import core.time : seconds;\n\n"
                ~ "    Thread.sleep(5.seconds);\n    assert(false, \"planted\");\n}\n",
        ]);
        RunOptions o;
        o.runnerCore = true;
        o.failFast = true;
        o.packages = [holder.name, failer.name];
        auto sw = StopWatch(AutoStart.yes);
        auto g = run(null, freshCache("cic11ff"), o);
        const took = sw.peek;
        // Killed processes are reaped by their new parent shortly after.
        string[] alive;
        foreach (attempt; 0 .. 50)
        {
            alive = null;
            if (exists(pids))
                foreach (line; readText(pids).lineSplitter)
                    if (line.strip.length && kill(line.strip.to!int, 0) == 0)
                        alive ~= line.strip.idup;
            if (!alive.length)
                break;
            import core.thread : Thread;

            Thread.sleep(100.msecs);
        }
        const recorded = exists(pids) ? readText(pids).lineSplitter.count : 0;
        vs ~= Verdict("step 2",
            g.error.length ? g.error
            : recorded < 3 ? text("the holding test recorded ", recorded, " of its 3 processes")
            : g.exitCode == 0 ? "the run passed over a failing test"
            : alive.length ? text("processes of the cancelled leg are alive: ", alive)
            : took > 240.seconds ? text("fail-fast took ", took) : null,
            text("a failing package ended the other's leg in ", took.total!"seconds",
                " s, and none of its ", recorded, " nested processes outlived it"));
        foreach (pid; alive)
            kill(pid.to!int, 9);
    }
    return vs;
}

// === ci task-DAG M8's gate: coverage attempts ===

/**
CIC7: a package that fails only under coverage is degraded, and the run
exits zero; one whose plain fallback fails too fails the run.
*/
Verdict[] oracleM8()
{
    import sparkles.build_graph.actions : TestLeg;

    Verdict[] vs;
    // A module that does not compile with `-cov`.
    enum covOnly = "version (D_Coverage) static assert(false, \"planted: no coverage build\");\n";
    foreach (step, failing; [false, true])
    {
        const name = failing ? "m8f" : "m8d";
        auto f = Fixture.add(name, [
            "dub.sdl": recipeOf(name),
            "src/sparkles/zz_" ~ name ~ "/t.d": "module sparkles.zz_" ~ name ~ ".t;\n\n" ~ covOnly
                ~ "unittest { assert(" ~ (failing ? "false" : "true") ~ "); }\n",
        ]);
        RunOptions o;
        o.runnerCore = true;
        o.coverage = true;
        o.legs = [TestLeg(2, true, "parallel")];
        auto g = run(f.name, freshCache("m8"), o);
        size_t covTests, plainTests;
        foreach (ref a; g.plan.graph.actions)
            if (a.kind == ActionKind.test && g.stats.executedTasks.canFind(a.id.text))
                a.action.match!(
                    (ref const ProcessAction p) {
                        if (p.argv.any!(x => x.startsWith("--DRT-covopt=")))
                            ++covTests;
                        else
                            ++plainTests;
                    },
                    (ref const _) {});
        vs ~= Verdict(failing ? "step 2" : "step 1",
            g.error.length ? g.error
            : covTests ? text(covTests, " coverage tests ran over a coverage build that cannot compile")
            : plainTests != 1 ? text("the plain fallback's test ran ", plainTests, " times, not once")
            : !failing && g.exitCode != 0 ? text("a package that fails only under coverage failed the run (exit ",
                g.exitCode, ")")
            : failing && g.exitCode == 0 ? "a failing plain fallback passed the run" : null,
            failing ? "a coverage build that failed, then a failing plain test, failed the run"
                : "a coverage build that failed fell back to the plain test, which passed, and the run exited zero");
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
        // The `ci` the worktree builds, brought up to date first.
        const built = execute(["dub", "build", "-q", "--root=" ~ root, ":ci"]);
        const ci = buildPath(root, "apps", "ci", "build", "ci");
        // explain reads the store beneath $XDG_CACHE_HOME/sparkles: point it here.
        const xdg = buildPath(scratch, "o24-xdg");
        mkdirRecurse(xdg);
        if (!exists(buildPath(xdg, "sparkles")))
            symlink(cache, buildPath(xdg, "sparkles"));
        const r = execute(["strace", "-f", "-qq", "-e", "trace=%file", "-o", traceFile, ci, "cache",
            "explain", compile], ["XDG_CACHE_HOME": xdg]);
        const trace = exists(traceFile) ? readText(traceFile) : "";
        vs ~= Verdict("step 5", built.status ? "cannot build `ci`:\n" ~ built.output
            : !planted.length ? "no object to plant a link at"
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

// === Oracle 8: the layout lint's revert check ===

/// With the lint, a field a library adds under `version (unittest)` fails
/// planning at its place; without it, the test plans and links, and
/// misreads the aggregate the library compiled without the field.
Verdict[] oracle8()
{
    auto lib = Fixture.add("o8l", [
        "dub.sdl": recipeOf("o8l"),
        "src/sparkles/zz_o8l/s.d": "module sparkles.zz_o8l.s;\n\nstruct S\n{\n    version (unittest) int x;\n    int y;\n}\n\n"
            ~ "int getY(ref const S s) => s.y;\n",
    ]);
    auto test = Fixture.add("o8t", [
        "dub.sdl": recipeOf("o8t", ["zz-oracle-o8l"]),
        "src/sparkles/zz_o8t/t.d": "module sparkles.zz_o8t.t;\n\nimport sparkles.zz_o8l.s;\n\n"
            ~ "unittest\n{\n    S s;\n    s.y = 5;\n    assert(getY(s) == 5);\n}\n",
    ]);
    auto linted = run(test.name, freshCache("o8"));
    RunOptions o;
    o.noLayoutLint = true;
    auto unlinted = run(test.name, freshCache("o8"), o);
    const link = taskOf(unlinted, test.task("link"));
    const t = taskOf(unlinted, test.task("test"));
    return [Verdict("revert check",
        !linted.error.canFind("s.d") ? "with the lint, planning did not fail at the field: " ~ linted.error
        : unlinted.error.length ? "without the lint, planning failed: " ~ unlinted.error
        : !executed(unlinted, link) || !stored(unlinted, link) ? "without the lint, the test did not link:" ~ tailOf(unlinted.log)
        : !executed(unlinted, t) || unlinted.exitCode == 0 ? "without the lint, the test read the aggregate right" : null,
        "the lint fails planning at the field; without it the test links and misreads the aggregate")];
}

// === Oracle 5: relocation ===

/// The files of the published result `key` beneath `cache`, by name, but
/// its log: what the action declared and made.
string[string] outputsOf(string cache, string key)
{
    import std.file : dirEntries, read, SpanMode;

    string[string] files;
    const out_ = buildPath(cache, "build", "v1", "results", key, "out");
    if (!exists(out_))
        return files;
    foreach (e; dirEntries(out_, SpanMode.depth))
        if (e.isFile && !e.name.endsWith("/output.log"))
            files[e.name[out_.length + 1 .. $]] = cast(string) read(e.name);
    return files;
}

Verdict[] oracle5()
{
    import std.process : execute;

    Verdict[] vs;
    const other = secondWorktree();
    scope (exit)
        removeWorktree(other);
    const cacheA = freshCache("o5"), cacheB = freshCache("o5");
    auto a = run("versions", cacheA);
    auto b = run("versions", cacheB, RunOptions.init, other);
    if (a.exitCode != 0 || b.exitCode != 0)
        return [Verdict("setup", "versions did not build in both worktrees:" ~ tailOf(a.log ~ b.log))];

    // Steps 1 and 2: equal keys, byte-identical outputs, and no worktree's path in them.
    {
        string why;
        if (a.stats.declaredKeys != b.stats.declaredKeys)
            why = "the declared keys differ between the worktrees";
        else if (a.stats.resultKeys != b.stats.resultKeys)
            why = "the result keys differ between the worktrees";
        else
            foreach (task, key; a.stats.resultKeys)
            {
                const fa = outputsOf(cacheA, key), fb = outputsOf(cacheB, key);
                if (fa != fb)
                    why ~= " " ~ task ~ "'s outputs differ;";
                foreach (name, bytes; fa)
                    if (bytes.canFind(root) || bytes.canFind(other))
                        why ~= " " ~ task ~ "'s " ~ name ~ " names a worktree;";
            }
        vs ~= Verdict("steps 1-2", why, text(a.stats.resultKeys.length,
            " results with equal keys and byte-identical outputs, naming neither worktree"));
    }

    // Step 3: the test binary built in A passes from B, opening B's files.
    {
        const link = taskOf(a, "link:sparkles.versions:");
        const key = a.stats.resultKeys.get(link, null);
        string binary;
        foreach (name, _; outputsOf(cacheA, key))
            binary = buildPath(cacheA, "build", "v1", "results", key, "out", name);
        const traceFile = buildPath(scratch, "o5.trace");
        const r = execute(["strace", "-f", "-qq", "-e", "trace=openat,open,stat,newfstatat", "-o", traceFile,
            binary, "--no-runner"], null, std.process.Config.none, size_t.max, other);
        const trace = exists(traceFile) ? readText(traceFile) : "";
        vs ~= Verdict("step 3", r.status != 0 ? "the binary from A failed in B:\n" ~ r.output
            : trace.canFind("\"" ~ root ~ "/") ? "the binary from A opened a file of A" : null,
            "the binary built in A passes from B and opens nothing of A's");
    }

    // Step 4: without the prefix map, the keys differ by the root.
    {
        RunOptions o;
        o.adjustPlan = (ref Planned p) {
            wrapActions(p, "compile:", (string[] argv) => argv.filter!(x => !x.startsWith("--ffile-prefix-map=")).array);
        };
        auto na = run("versions", freshCache("o5"), o);
        auto nb = run("versions", freshCache("o5"), o, other);
        const compile = taskOf(na, "compile:sparkles.versions:test-root:");
        vs ~= Verdict("step 4", na.stats.declaredKeys.get(compile, "a") == nb.stats.declaredKeys.get(compile, "b")
            ? "without a prefix map, the two worktrees' compiles share a key" : null,
            "without a prefix map, the compile's key differs between the worktrees");
    }

    // Step 5: examples through the graph.
    vs ~= Verdict("step 5", "not run: `ci docs verify` builds its examples with dub, not through the graph", null);

    // Step 6: no output names the toolchain's druntime or Phobos sources.
    {
        string why;
        if (!a.toolchain.root.length)
            why = "the toolchain reported no tree of its own";
        foreach (task, key; a.stats.resultKeys)
            foreach (name, bytes; outputsOf(cacheA, key))
                if (bytes.canFind(a.toolchain.root ~ "/include"))
                    why ~= " " ~ task ~ "'s " ~ name ~ " names " ~ a.toolchain.root ~ "/include;";
        vs ~= Verdict("step 6", why, "no output, test binary included, names the toolchain's druntime or Phobos sources");
    }
    return vs;
}

// === Oracle 9: key sensitivity ===

/// The tasks whose declared key differs between `before` and `after`.
string[] changedKeys(const string[string] before, const string[string] after)
{
    string[] tasks;
    foreach (task, key; after)
        if (auto was = task in before)
            if (*was != key)
                tasks ~= task;
    return tasks.sort.release;
}

/// An executable shell script at `path`: `body` after its shebang.
void script(string path, string body)
{
    import std.file : setAttributes;

    mkdirRecurse(dirName(path));
    write(path, "#!" ~ sh() ~ "\n" ~ body ~ "\n");
    setAttributes(path, octal!755);
}

/// An empty static library at `path`, made by the archiver on `PATH`.
void emptyArchive(string path)
{
    import std.process : execute;

    mkdirRecurse(dirName(path));
    const r = execute([tool("ar"), "rcs", path]);
    assert(r.status == 0, r.output);
}

/// Sets environment variables for the scope's length.
struct Environment
{
    private string[string] before;
    private bool[string] unset;

    @disable this(this);

    static Environment set(string[string] values)
    {
        Environment e;
        foreach (name, value; values)
        {
            if (auto v = std.process.environment.get(name))
                e.before[name] = v;
            else
                e.unset[name] = true;
            std.process.environment[name] = value;
        }
        return e;
    }

    ~this()
    {
        foreach (name, value; before)
            std.process.environment[name] = value;
        foreach (name, _; unset)
            std.process.environment.remove(name);
    }
}

Verdict[] oracle9()
{
    import sparkles.build_graph.actions : Action, DeclaredOutput;
    import sparkles.build_graph.store : manifestExtraction;
    import sparkles.build_primitives.task.action : EnvEntry, TaskAction;
    import sparkles.build_primitives.task.model : taskId;

    Verdict[] vs;
    const dirA = buildPath(scratch, "o9-lib-a"), dirB = buildPath(scratch, "o9-lib-b");
    mkdirRecurse(dirA);
    emptyArchive(buildPath(dirB, "libzzo9.a"));
    emptyArchive(buildPath(dirB, "libzzo9p.a"));
    enum libModule = "module sparkles.zz_o9l.lib;\n\n// The library the test links.\nint twice(int x) { return 2 * x; }\n";
    auto lib = Fixture.add("o9l", [
        "dub.sdl": recipeOf("o9l"),
        "src/sparkles/zz_o9l/lib.d": libModule,
    ]);
    auto app = Fixture.add("o9t", [
        "dub.sdl": recipeOf("o9t", ["zz-oracle-o9l"], null, null, (ref DubManifest m) {
            m.lflags = [platformValues("-L" ~ dirA, "-L" ~ dirB)];
            m.libs = [platformValues("zzo9")];
        }),
        "src/sparkles/zz_o9t/t.d": "module sparkles.zz_o9t.t;\n\nimport sparkles.zz_o9l.lib;\n\npragma(lib, \"zzo9p\");\n\n"
            ~ "unittest\n{\n    assert(twice(2) == 4);\n}\n",
    ]);
    const cache = freshCache("o9");
    auto base = run(app.name, cache);
    if (base.exitCode != 0)
        return [Verdict("setup", "the fixture did not build:" ~ tailOf(base.log))];
    const libCompile = taskOf(base, lib.task("compile"));
    const appCompile = taskOf(base, app.task("compile"));
    const link = taskOf(base, app.task("link"));
    const keyed = base.stats.declaredKeys.keys.sort.release;

    // The components of the declared key: each changes the keys it affects.
    {
        RunOptions o;
        o.adjustPlan = (ref Planned p) {
            wrapActions(p, libCompile, (string[] argv) => argv ~ "-d-version=ZzOracle9");
        };
        const changed = changedKeys(base.stats.declaredKeys, run(app.name, cache, o).stats.declaredKeys);
        vs ~= Verdict("an argument", changed != [libCompile] ? text("changed ", changed, ", not the one compile") : null,
            "one more argument to the library's compile changed its key alone");
    }
    {
        enum generator = "generate:oracle-9:environment:ldc:0";
        RunOptions with_(string value)
        {
            RunOptions o;
            o.adjustPlan = (ref Planned p) {
                p.graph.actions ~= Action(ActionKind.generate, taskId("generate", "oracle-9", "environment", "ldc", "0").value,
                    0, TaskAction(ProcessAction(argv: [tool("true")], envDelta: [EnvEntry("PATH", ""), EnvEntry("ZZ", value)])),
                    [DeclaredOutput(".", true)], 1);
            };
            return o;
        }
        const one = run(app.name, cache, with_("1")).stats.declaredKeys;
        const two = run(app.name, cache, with_("2")).stats.declaredKeys;
        const changed = changedKeys(one, two);
        vs ~= Verdict("an environment entry", changed != [generator] ? text("changed ", changed) : null,
            "another value of an action's declared environment entry changed that action's key alone");
    }
    // A toolchain component: every build action reads the toolchain.
    foreach (component; ["compiler", "C driver", "linker"])
    {
        RunOptions o;
        o.adjustTools = (ref Tools t) {
            string* which = component == "compiler" ? &t.compiler : component == "C driver" ? &t.cc : &t.linker;
            const wrapper = buildPath(scratch, "o9-wrapped-" ~ component.replace(" ", "-"));
            script(wrapper, "exec " ~ *which ~ " \"$@\"");
            *which = wrapper;
        };
        const changed = changedKeys(base.stats.declaredKeys, run(app.name, cache, o).stats.declaredKeys);
        vs ~= Verdict("another " ~ component, changed != keyed ? text("changed ", changed.length, " of ", keyed.length, " keys") : null,
            text("another ", component, " changed every one of the ", keyed.length, " keys"));
    }
    {
        // The test runner's core keys only a test, and no test is keyed (BGX2).
        const copy = buildPath(scratch, "o9-runner");
        script(copy, "exec " ~ std.process.environment.get("SPARKLES_TEST_RUNNER", "false") ~ " \"$@\"");
        auto env = Environment.set(["SPARKLES_TEST_RUNNER": copy]);
        const changed = changedKeys(base.stats.declaredKeys, run(app.name, cache).stats.declaredKeys);
        vs ~= Verdict("another runner core", changed.length ? text("a build action's key changed: ", changed) : null,
            "another test runner changed no build action's key");
    }

    // Search inputs (BGK9).
    foreach (lib_; [["libzzo9.a", "a `-l` library"], ["libzzo9p.a", "a `pragma(lib)` library"]])
    {
        const earlier = buildPath(dirA, lib_[0]);
        emptyArchive(earlier);
        scope (exit)
        {
            import std.file : remove;

            remove(earlier);
        }
        const changed = changedKeys(base.stats.declaredKeys, run(app.name, cache).stats.declaredKeys);
        vs ~= Verdict(lib_[1] ~ " earlier on -L", changed != [link] ? text("changed ", changed, ", not the link alone") : null,
            lib_[1] ~ " created earlier on the -L order changed the link's key alone");
    }
    {
        const p1 = buildPath(scratch, "o9-pc-1"), p2 = buildPath(scratch, "o9-pc-2");
        mkdirRecurse(p1);
        mkdirRecurse(p2);
        enum pc = "Name: zzoracle9pc\nDescription: oracle 9\nVersion: 1\nLibs:\nCflags:\n";
        write(buildPath(p2, "zzoracle9pc.pc"), pc);
        const path = p1 ~ ":" ~ p2 ~ ":" ~ std.process.environment.get("PKG_CONFIG_PATH", "");
        auto env = Environment.set(["PKG_CONFIG_PATH": path, "PKG_CONFIG_PATH_x86_64_unknown_linux_gnu": path]);
        forgetPkgConfigAnswers();
        scope (exit)
            forgetPkgConfigAnswers();
        auto pcPkg = Fixture.add("o9p", [
            "dub.sdl": recipeOf("o9p", null, null, null, (ref DubManifest m) {
                m.libs = [platformValues("zzoracle9pc")];
            }),
            "src/sparkles/zz_o9p/p.d": "module sparkles.zz_o9p.p;\n\nunittest {}\n",
        ]);
        const pcCache = freshCache("o9");
        auto before = run(pcPkg.name, pcCache);
        write(buildPath(p1, "zzoracle9pc.pc"), pc);
        auto after = run(pcPkg.name, pcCache);
        const pcLink = taskOf(before, pcPkg.task("link"));
        const changed = changedKeys(before.stats.declaredKeys, after.stats.declaredKeys);
        vs ~= Verdict("a .pc file earlier on pkg-config's path", !changed.canFind(pcLink)
            ? text("the link using the query kept its key; changed ", changed) : null,
            text("a .pc file created earlier on the search path changed the keys of ", changed.length,
                " actions using the query"));
    }

    // The manifest extraction's version alone changes every compile's result key.
    {
        manifestExtraction = 2;
        auto other = run(app.name, freshCache("o9"));
        manifestExtraction = 1;
        auto same = run(app.name, freshCache("o9"));
        string[] kept;
        foreach (task, key; same.stats.resultKeys)
            if (task.startsWith("compile:") && other.stats.resultKeys.get(task, null) == key)
                kept ~= task;
        vs ~= Verdict("the manifest extraction's version", kept.length ? text("kept their result keys: ", kept) : null,
            "another manifest extraction version changed every compile's result key");
    }

    // Early cutoff: a comment edited in place reruns its compile alone; the
    // archives' headers carry no time, owner or group, and none is thin.
    {
        lib.put("src/sparkles/zz_o9l/lib.d", libModule.replace("// The library the test links.",
            "// The library a test links."));
        auto cut = run(app.name, cache);
        lib.put("src/sparkles/zz_o9l/lib.d", libModule);
        string[] downstream;
        foreach (t; cut.stats.executedTasks)
            if (!t.startsWith("compile:") && !t.startsWith("test:"))
                downstream ~= t;
        string archives;
        foreach (task, key; cut.stats.resultKeys)
            foreach (name, bytes; outputsOf(cache, key))
                if (name.endsWith(".a"))
                    archives ~= archiveHeaderFault(name, bytes);
        vs ~= Verdict("early cutoff", !executed(cut, libCompile) ? "the edited module's compile did not rerun"
            : downstream.length ? text("ran downstream of a comment edit: ", downstream)
            : cut.stats.declaredKeys.get(link, null) != base.stats.declaredKeys.get(link, null) ? "the link's key changed"
            : archives.length ? archives : null,
            "a comment edited in place reran the compiles that read it, and no archive, link or test key downstream changed; every archive has zero times, owners and groups");
    }

    // Environment probes (BGA4).
    {
        Tools found;
        Toolchain identity;
        cast(void) pathTools(found, identity);
        const bin = buildPath(scratch, "o9-recording");
        const calls = buildPath(bin, "calls");
        // They record only once the plan is about to run: the driver's own probe
        // of the toolchain, before it, is not an action.
        const armed = buildPath(bin, "armed");
        script(buildPath(bin, "cc"), "[ -e " ~ armed ~ " ] && echo cc \"$@\" >> " ~ calls ~ "\nexit 1");
        script(buildPath(bin, "ld"), "[ -e " ~ armed ~ " ] && echo ld \"$@\" >> " ~ calls ~ "\nexit 1");
        auto env = Environment.set(["PATH": bin ~ ":" ~ std.process.environment.get("PATH", "")]);
        RunOptions o;
        o.adjustTools = (ref Tools t) { t = found; };
        o.adjustPlan = (ref Planned) { write(armed, ""); };
        auto g = run(app.name, freshCache("o9"), o);
        bool absolute = true;
        // A compile names the C driver; a link the driver and the linker's
        // directory, which fixes the linker the driver runs.
        foreach (ref a; g.plan.graph.actions)
        {
            const argv = argvOf(g, a.id.text);
            if (a.kind == ActionKind.compile)
                absolute &= argv.canFind("-gcc=" ~ found.cc);
            else if (a.kind == ActionKind.link)
                absolute &= argv.canFind("-gcc=" ~ found.cc) && argv.canFind("-Xcc=-B" ~ dirName(found.linker));
        }
        vs ~= Verdict("a recording cc and ld on PATH", exists(calls) ? "an action called them: " ~ readText(calls)
            : !absolute ? "a compile or link does not name its toolchain's driver and linker by absolute path"
            : g.exitCode != 0 ? "the run failed:" ~ tailOf(g.log) : null,
            "no action called them; every compile and link names the toolchain's driver and linker");
    }
    {
        auto env = Environment.set(["DFLAGS": "-d-version=ZzOracle9Env", "CC": "/nonexistent/cc",
            "NIX_CFLAGS_COMPILE": "-DZZ_ORACLE_9"]);
        const probed = freshCache("o9");
        auto g = run(app.name, probed);
        string differs;
        if (changedKeys(base.stats.declaredKeys, g.stats.declaredKeys).length)
            differs = "a key changed";
        foreach (task, key; g.stats.resultKeys)
            if (outputsOf(probed, key) != outputsOf(cache, base.stats.resultKeys.get(task, key)))
                differs ~= " " ~ task ~ "'s outputs differ;";
        vs ~= Verdict("DFLAGS, CC and NIX_CFLAGS_COMPILE set", differs,
            "no key and no output changed with them in the driver's environment");
    }
    {
        // libfaketime hangs LDC, so the clock moves by waiting: the outputs
        // must not follow it (SOURCE_DATE_EPOCH pins all three), and without
        // SOURCE_DATE_EPOCH they must, which shows the check can see it.
        string datedLog;
        auto dated = Fixture.add("o9d", [
            "dub.sdl": recipeOf("o9d"),
            "src/sparkles/zz_o9d/d.d": "module sparkles.zz_o9d.d;\n\nimport sparkles.zz_o9d.c_dated;\n\n"
                ~ "string when() => __DATE__ ~ __TIME__ ~ __TIMESTAMP__;\n",
            "src/sparkles/zz_o9d/c_dated.c": "const char *zz_when = __DATE__ __TIME__ __TIMESTAMP__;\n",
        ]);
        string[string] objects(bool pinned)
        {
            import core.thread : Thread;
            import std.datetime.systime : Clock;
            import std.file : setTimes;

            Thread.sleep(2.seconds);
            foreach (src; ["src/sparkles/zz_o9d/d.d", "src/sparkles/zz_o9d/c_dated.c"])
                setTimes(buildPath(dated.dir, src), Clock.currTime, Clock.currTime);
            RunOptions o;
            if (!pinned)
                o.adjustExecution = (string task, ref ProcessAction pa) {
                    import sparkles.build_primitives.task.action : EnvEntry;

                    if (task.startsWith("compile:"))
                        pa.envDelta = pa.envDelta.filter!(e => e.name != "SOURCE_DATE_EPOCH").array;
                };
            const cache = freshCache("o9");
            auto g = run(dated.name, cache, o);
            datedLog = tailOf(g.log);
            string[string] all;
            foreach (task, key; g.stats.resultKeys)
                if (task.startsWith(dated.task("compile")))
                    foreach (name, bytes; outputsOf(cache, key))
                        all[name] = bytes;
            return all;
        }
        const first = objects(true), second = objects(true);
        const unpinnedA = objects(false), unpinnedB = objects(false);
        vs ~= Verdict("__DATE__, __TIME__ and __TIMESTAMP__", !first.length ? "the dated fixture built nothing:" ~ datedLog
            : first != second ? "the outputs followed the clock"
            : unpinnedA == unpinnedB ? "without SOURCE_DATE_EPOCH the outputs did not follow the clock either: the check sees nothing"
            : null,
            "a D module and an ImportC source that embed the date and time compile to the same bytes two seconds and "
            ~ "new modification times apart (libfaketime hangs LDC, so no day passes); without SOURCE_DATE_EPOCH they differ");
    }
    return vs;
}

/// What is wrong with the `ar` archive `bytes` (`name`): a thin archive, or a
/// member header with a time, owner or group. Empty when nothing is.
string archiveHeaderFault(string name, string bytes)
{
    import std.string : strip;

    if (bytes.startsWith("!<thin>\n"))
        return name ~ " is thin; ";
    if (!bytes.startsWith("!<arch>\n"))
        return null;
    size_t at = 8;
    while (at + 60 <= bytes.length)
    {
        const h = bytes[at .. at + 60];
        // The symbol table (`/`) and the long-name table (`//`) carry no
        // time or owner: their fields may be blank.
        const special = h[0] == '/' && (h[1] == ' ' || h[1] == '/');
        if (!special && (h[16 .. 28].strip != "0" || h[28 .. 34].strip != "0" || h[34 .. 40].strip != "0"))
            return text(name, ": member `", h[0 .. 16].strip, "` has time ", h[16 .. 28].strip, ", owner ",
                h[28 .. 34].strip, " and group ", h[34 .. 40].strip, "; ");
        size_t size;
        foreach (c; h[48 .. 58].strip)
            size = size * 10 + (c - '0');
        at += 60 + size + (size & 1);
    }
    return null;
}

// === Oracle 7: concurrency ===

/// The value of the option `--<name>=` in `args`, or null.
string option(string[] args, string name)
{
    foreach (a; args)
        if (a.startsWith("--" ~ name ~ "="))
            return a["--".length + name.length + 1 .. $];
    return null;
}

__gshared string pauseFile;    // a child pauses at its first publication, naming its key here
__gshared string barrierDir;   // a child waits at its first publication for `barrierCount` others
__gshared size_t barrierCount;
__gshared bool randomDelay;    // a child sleeps up to 200 ms before each publication
__gshared bool firstPassed;

void beforeEachPublication(string key) @trusted
{
    import core.thread : Thread;
    import std.file : dirEntries, SpanMode;
    import std.random : uniform;

    if (randomDelay)
        Thread.sleep(uniform(0, 200).msecs);
    if (firstPassed)
        return;
    firstPassed = true;
    if (barrierDir.length)
    {
        try
        {
            write(buildPath(barrierDir, text(thisProcessID)), key);
            while (dirEntries(barrierDir, SpanMode.shallow).array.length < barrierCount)
                Thread.sleep(20.msecs);
        }
        catch (Exception) {}
    }
    if (pauseFile.length)
    {
        try
            write(pauseFile, key);
        catch (Exception) {}
        while (true)
            Thread.sleep(1.seconds);
    }
}

/**
A builder of oracle 7: plans `--child=<package>`'s test root in `--at=` (the
worktree; `root` otherwise) and runs it against the store beneath `--cache=`,
in a run directory of its own. `--delay` sleeps before each publication,
`--pause=<file>` stops at the first, `--barrier=<dir>:<n>` holds the first
until `n` builders reach theirs, `--counter=<task prefix>` appends this
process's id to that compile's objects, so builders' outputs differ, and
`--task=` runs one task. Prints `exit`, `result`, `executed` and `log` lines.
*/
int childBuild(string[] args)
{
    import std.algorithm : countUntil;
    import sparkles.build_graph.store : beforePublication;

    const at = option(args, "at");
    root = buildNormalizedPath(absolutePath(at.length ? at : "."));
    const cache = option(args, "cache");
    randomDelay = args.canFind("--delay");
    pauseFile = option(args, "pause");
    if (const b = option(args, "barrier"))
    {
        barrierDir = b[0 .. b.countUntil(':')];
        barrierCount = b[b.countUntil(':') + 1 .. $].to!size_t;
    }
    beforePublication = &beforeEachPublication;
    RunOptions o;
    o.cache = cache;
    o.into = buildPath(cache, "runs", text("child-", thisProcessID));
    o.jobs = 2;
    if (const t = option(args, "task"))
        o.tasks = [t];
    // Oracle 16: the file system is full once the task's process ends,
    // before its publication writes anything.
    if (const prefix = option(args, "fill-after"))
        o.adjustExecution = (string task, ref ProcessAction pa) {
            if (task.startsWith(prefix))
                pa.argv = [sh(), "-c", "\"$0\" \"$@\"; s=$?; " ~ tool("dd") ~ " if=/dev/zero of=" ~ cache
                    ~ "/filler bs=64k 2>/dev/null; exit $s"] ~ pa.argv;
        };
    if (const prefix = option(args, "counter"))
        o.adjustExecution = (string task, ref ProcessAction pa) {
            if (!task.startsWith(prefix))
                return;
            string objects;
            foreach (arg; pa.argv)
                if (arg.startsWith("-of="))
                    objects ~= " \"" ~ arg[4 .. $] ~ "\"";
            pa.argv = [sh(), "-c", "\"$0\" \"$@\" && for o in" ~ objects ~ "; do echo " ~ text(thisProcessID)
                ~ " >> \"$o\"; done"] ~ pa.argv;
        };
    auto g = runGraph(root, option(args, "child"), o);
    writeln("exit ", g.error.length ? -1 : g.exitCode);
    if (g.error.length)
        writeln("error ", g.error);
    foreach (task, key; g.stats.resultKeys)
        writeln("result ", task, " ", key);
    foreach (task; g.stats.executedTasks)
        writeln("executed ", task);
    foreach (line; g.log.lineSplitter)
        writeln("log ", line);
    return 0;
}

__gshared string renameBlockCache;

// Oracle 16: plants a file where the entry `key` would be published, so the
// publishing rename fails.
void blockRename(string key) @trusted
{
    try
        write(buildPath(renameBlockCache, "build", "v1", "results", key), "in the way");
    catch (Exception) {}
}

/// A builder's report, parsed.
struct ChildReport
{
    int exitCode = -2;
    string[string] resultKeys;
    string[] executed;
    string log;
    string raw;
}

ChildReport parseChild(string output)
{
    import std.algorithm : countUntil;
    ChildReport r;
    r.raw = output;
    foreach (line; output.lineSplitter)
    {
        if (line.startsWith("exit "))
            r.exitCode = line[5 .. $].to!int;
        else if (line.startsWith("result "))
        {
            const rest = line[7 .. $];
            const sp = rest.countUntil(' ');
            r.resultKeys[rest[0 .. sp]] = rest[sp + 1 .. $];
        }
        else if (line.startsWith("executed "))
            r.executed ~= line[9 .. $].idup;
        else if (line.startsWith("log "))
            r.log ~= line[4 .. $] ~ "\n";
    }
    return r;
}

/// A builder started: its process and the file its report goes to.
struct Child
{
    std.process.Pid pid;
    string output;

    ChildReport wait()
    {
        cast(void) std.process.wait(pid);
        return parseChild(exists(output) ? readText(output) : "");
    }
}

Child startChild(string pkg, string cache, string[] extra = null, string[] wrap = null)
{
    import std.file : thisExePath;
    import std.stdio : File;

    static size_t n;
    const output = buildPath(scratch, text("child-", ++n, ".out"));
    auto f = File(output, "w");
    auto pid = std.process.spawnProcess(wrap ~ [thisExePath, "--child=" ~ pkg, "--cache=" ~ cache] ~ extra,
        std.stdio.stdin, f, f, null, std.process.Config.none, root);
    return Child(pid, output);
}

/// The names in the store's `sub` directory beneath `cache`.
string[] storeDir(string cache, string sub)
{
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;

    const dir = buildPath(cache, "build", "v1", sub);
    return exists(dir) ? dirEntries(dir, SpanMode.shallow).map!(e => baseName(e.name)).array.sort.release : null;
}

/// `ci cache` operations against the store beneath `cache`: its exit status and lines.
int storeOp(string cache, string op, out string lines)
{
    import std.array : appender;
    import sparkles.build_graph.execute : storeOperation;

    auto w = appender!string;
    const status = storeOperation(cache, op, w);
    lines = w[];
    return status;
}

/// Waits up to `limit` for `path` to exist.
bool awaitFile(string path, core.time.Duration limit = 600.seconds)
{
    import core.thread : Thread;
    import std.datetime.stopwatch : StopWatch, AutoStart;

    auto sw = StopWatch(AutoStart.yes);
    while (!exists(path) || readText(path).length == 0)
    {
        if (sw.peek > limit)
            return false;
        Thread.sleep(50.msecs);
    }
    return true;
}

/// The device of the file system `path` is on.
ulong deviceOf(string path)
{
    import core.sys.posix.sys.stat : stat, stat_t;
    import std.string : toStringz;

    stat_t s;
    return (() @trusted => stat(path.toStringz, &s))() == 0 ? s.st_dev : 0;
}

Verdict[] oracle7()
{
    import core.sys.posix.signal : SIGKILL;

    Verdict[] vs;

    // Step 1: N builders of one package, at random delays before each
    // publication, from two worktrees on different file systems, while a
    // reader verifies the store over and over. The second worktree goes
    // beneath the system's temporary directory, since `ORACLE_SCRATCH` may put
    // the scratch directory beside the first (oracle 4).
    {
        const other = secondWorktree(tempDir);
        scope (exit)
            removeWorktree(other);
        const cache = freshCache("o7");
        Child[] children;
        foreach (i; 0 .. 4)
            children ~= startChild("versions", cache, ["--delay"] ~ (i % 2 ? ["--at=" ~ other] : null));
        string corrupt;
        size_t reads, midPublication;
        bool running = true;
        while (running)
        {
            string lines;
            // A `sometimes` property: a pass says nothing of the race unless
            // some verification began with a publication in flight.
            midPublication += storeDir(cache, "staging").length > 0;
            if (storeOp(cache, "verify", lines) != 0)
                corrupt ~= lines;
            ++reads;
            running = children.any!(c => !std.process.tryWait(c.pid).terminated);
        }
        ChildReport[] reports = children.map!(c => c.wait()).array;
        string why;
        foreach (i, ref r; reports)
            if (r.exitCode != 0)
                why ~= text(" builder ", i, " failed:", tailOf(r.log ~ r.raw));
            else if (r.resultKeys != reports[0].resultKeys)
                why ~= text(" builder ", i, "'s result keys differ from builder 0's;");
            else if (r.log.canFind("cannot publish"))
                why ~= text(" builder ", i, " could not publish:", tailOf(r.log));
        if (deviceOf(other) == deviceOf(root))
            why ~= " the two worktrees are on one file system;";
        if (deviceOf(buildPath(cache, "runs")) != deviceOf(buildPath(cache, "build")))
            why ~= " the run directories and the store are on different file systems;";
        if (!midPublication)
            why ~= text(" none of the ", reads, " verifications began with a publication in flight;");
        vs ~= Verdict("step 1", corrupt.length ? "a reader saw a partial entry: " ~ corrupt : why,
            text("4 builders from two worktrees on different file systems agreed on ", reports[0].resultKeys.length,
                " result keys; ", reads, " verifications while they ran, ", midPublication, " of them begun with a "
                ~ "publication in flight, found no partial entry, and every publication was a rename within the "
                ~ "store's file system"));
    }

    // The fixture every later step builds, with its dependencies published
    // once beforehand, so a builder's first publication is its compile.
    auto lib = Fixture.add("o7l", [
        "dub.sdl": recipeOf("o7l"),
        "src/sparkles/zz_o7l/d.d": "module sparkles.zz_o7l.d;\n\nint dep() { return 7; }\n",
    ]);
    auto app = Fixture.add("o7t", [
        "dub.sdl": recipeOf("o7t", ["zz-oracle-o7l"]),
        "src/sparkles/zz_o7t/t.d": "module sparkles.zz_o7t.t;\n\nimport sparkles.zz_o7l.d;\n\n"
            ~ "unittest\n{\n    assert(dep() == 7);\n}\n",
    ]);
    // A store holding everything but `app`'s own compile and link.
    string seeded(out GraphRun g)
    {
        const cache = freshCache("o7");
        g = run(app.name, cache);
        string lines;
        foreach (kind; ["compile", "link"])
            cast(void) storeOp(cache, "remove-task=" ~ taskOf(g, app.task(kind)), lines);
        return cache;
    }

    // Step 2: a producer killed between its write and its rename.
    {
        GraphRun g;
        const cache = seeded(g);
        const pause = buildPath(scratch, "o7-pause");
        auto c = startChild(app.name, cache, ["--pause=" ~ pause]);
        const reached = awaitFile(pause);
        std.process.kill(c.pid, SIGKILL);
        cast(void) c.wait();
        const key = reached ? readText(pause) : null;
        const staged = storeDir(cache, "staging");
        string lines;
        cast(void) storeOp(cache, "gc", lines);
        vs ~= Verdict("step 2", !reached ? "the producer never reached a publication"
            : storeDir(cache, "results").canFind(key) ? "the killed producer's result was published"
            : !staged.length ? "the killed producer left no staging entry"
            : storeDir(cache, "staging").length ? "garbage collection left the staging entry"
            : null,
            "the producer killed before its rename left only a staging entry, and garbage collection removed it");
    }

    // Step 3: eviction beside a live lease holder, then a killed one; and
    // garbage collection and eviction over and over while builders run.
    {
        GraphRun g;
        const cache = seeded(g);
        const pause = buildPath(scratch, "o7-hold");
        auto c = startChild(app.name, cache, ["--pause=" ~ pause]);
        const childId = text(c.pid.processID, "-");
        const reached = awaitFile(pause);
        // The results the paused builder leases: its holder name starts with its id.
        const held = storeDir(cache, "leases").filter!(k => storeDir(cache, "leases/" ~ k)
            .any!(h => h.startsWith(childId))).array;
        // A lookup leases a key before it reads the record, so a missed key is
        // leased too: only the published ones can be evicted.
        const resultsBefore = storeDir(cache, "results");
        const leasedResults = held.filter!(k => resultsBefore.canFind(k)).array;
        string first, second;
        cast(void) storeOp(cache, "evict=0", first);
        const keptWhileAlive = leasedResults.all!(k => storeDir(cache, "results").canFind(k));
        std.process.kill(c.pid, SIGKILL);
        cast(void) c.wait();
        cast(void) storeOp(cache, "gc", second);
        const leasesAfter = held.filter!(k => storeDir(cache, "leases/" ~ k)
            .any!(h => h.startsWith(childId))).array;
        cast(void) storeOp(cache, "evict=0", second);
        const leftAfter = leasedResults.filter!(k => storeDir(cache, "results").canFind(k)).array;
        vs ~= Verdict("step 3, a lease holder", !reached ? "the holder never reached a publication"
            : !leasedResults.length ? "the paused builder leased no published result"
            : !keptWhileAlive ? "eviction removed a result a live holder leased: " ~ first
            : leasesAfter.length ? text("garbage collection left the dead holder's leases: ", leasesAfter)
            : leftAfter.length ? text("eviction after the holder died kept ", leftAfter) : null,
            text("eviction kept the ", leasedResults.length, " results a live holder leased; once it was killed, garbage "
                ~ "collection reclaimed its leases and eviction removed them"));

        const busy = freshCache("o7");
        Child[] children;
        foreach (i; 0 .. 3)
            children ~= startChild("versions", busy, ["--delay"]);
        size_t sweeps, midPublication, leased;
        while (children.any!(ch => !std.process.tryWait(ch.pid).terminated))
        {
            string lines;
            // `sometimes` properties: some round must meet a publication in
            // flight, and some a live lease, or the pass shows nothing.
            midPublication += storeDir(busy, "staging").length > 0;
            leased += storeDir(busy, "leases").any!(k => storeDir(busy, "leases/" ~ k).length > 0);
            cast(void) storeOp(busy, "gc", lines);
            cast(void) storeOp(busy, "evict=0", lines);
            ++sweeps;
        }
        string why;
        foreach (i, ch; children)
        {
            const r = ch.wait();
            if (r.exitCode != 0)
                why ~= text(" builder ", i, " failed:", tailOf(r.log ~ r.raw));
        }
        if (!midPublication)
            why ~= text(" none of the ", sweeps, " rounds began with a publication in flight;");
        if (!leased)
            why ~= text(" none of the ", sweeps, " rounds began with a live lease;");
        vs ~= Verdict("step 3, collection while building", why,
            text("3 builders succeeded while ", sweeps, " rounds of garbage collection and eviction to nothing ran, ",
                midPublication, " of them begun with a publication in flight and ", leased, " with a live lease"));
    }

    // Step 4: the losing producer (BGS3).
    {
        GraphRun g;
        const cache = seeded(g);
        const compile = taskOf(g, app.task("compile")), link = taskOf(g, app.task("link"));
        const barrier = buildPath(scratch, "o7-barrier");
        mkdirRecurse(barrier);
        Child[] children;
        foreach (i; 0 .. 2)
            children ~= startChild(app.name, cache, ["--barrier=" ~ barrier ~ ":2", "--counter=" ~ app.task("compile")]);
        auto reports = children.map!(c => c.wait()).array;
        const key = reports[0].resultKeys.get(compile, null);
        const losers = reports.count!(r => r.log.canFind("nondeterministic: result " ~ key) && r.log.canFind(".o"));
        const linkKey = reports[0].resultKeys.get(link, null);
        vs ~= Verdict("step 4", reports.any!(r => r.exitCode != 0) ? "a builder failed:" ~ tailOf(reports[0].log ~ reports[1].log)
            : !key.length || reports[1].resultKeys.get(compile, null) != key ? "the builders' compile keys differ"
            : losers != 1 ? text(losers, " builders reported the compile nondeterministic, not one:", tailOf(reports[0].log ~ reports[1].log, 30))
            : !linkKey.length || reports[1].resultKeys.get(link, null) != linkKey ? "the two links' keys differ"
            : !storeDir(cache, "results").canFind(linkKey) ? "the store does not hold the link's result" : null,
            "of two builders publishing one compile key with different objects, the loser reported it nondeterministic, "
            ~ "naming the key and the object, and both links consumed the winner's: one link key, which the store holds");
    }

    // Step 5: lookup at admission (BGS4).
    {
        GraphRun g;
        const cache = seeded(g);
        const compile = taskOf(g, app.task("compile"));
        RunOptions o;
        string other;
        o.adjustPlan = (ref Planned) {
            other = startChild(app.name, cache, ["--task=" ~ compile]).wait().raw;
        };
        auto admitted = run(app.name, cache, o);
        vs ~= Verdict("step 5", !other.canFind("executed " ~ compile) ? "the other process did not compile:" ~ tailOf(other)
            : executed(admitted, compile) ? "the compile another process published after planning was executed again"
            : admitted.exitCode != 0 ? "the run failed:" ~ tailOf(admitted.log) : null,
            "a compile another process published after planning hit at admission");
    }

    // Two worktrees alternating between two manifests of one declared key.
    {
        const other = secondWorktree();
        scope (exit)
            removeWorktree(other);
        copyFixture(lib, other);
        copyFixture(app, other);
        write(buildPath(other, "libs", lib.name, "src/sparkles/zz_o7l/d.d"),
            "module sparkles.zz_o7l.d;\n\nint dep() { return 7; } // the other worktree's\n");
        const cache = freshCache("o7");
        auto a1 = run(app.name, cache), b1 = run(app.name, cache, RunOptions.init, other);
        auto a2 = run(app.name, cache), b2 = run(app.name, cache, RunOptions.init, other);
        const compile = taskOf(a1, app.task("compile"));
        string[] rebuilt;
        foreach (r; [a2, b2])
            foreach (t; r.stats.executedTasks)
                if (!t.startsWith("test:"))
                    rebuilt ~= t;
        vs ~= Verdict("alternating manifests", a1.exitCode || b1.exitCode || a2.exitCode || b2.exitCode
            ? "a run failed:" ~ tailOf(a1.log ~ b1.log ~ a2.log ~ b2.log)
            : a1.stats.declaredKeys.get(compile, "a") != b1.stats.declaredKeys.get(compile, "b") ? "the two worktrees' compiles have different declared keys"
            : a1.stats.resultKeys.get(compile, "a") == b1.stats.resultKeys.get(compile, "a") ? "the two worktrees' compiles share a manifest"
            : rebuilt.length ? text("the second round rebuilt ", rebuilt) : null,
            "two worktrees whose compile has one declared key and two manifests both kept hitting, alternating");
    }
    return vs;
}

// === Oracle 2: build equivalence ===

/// The verdict lines of a test runner's report in `output` (` ✓ <module>
/// <name>`, and the summary's counts without its time), without colours,
/// sorted.
string[] verdictLines(string output)
{
    import std.regex : ctRegex, replaceAll;
    import std.string : strip;

    enum ansi = ctRegex!`\x1b\[[0-9;]*m`;
    enum time = ctRegex!` in [0-9.]+(ms|µs|ns|s|m|m [0-9.]+s)$`;
    string[] lines;
    foreach (raw; output.lineSplitter)
    {
        auto line = raw.idup.replaceAll(ansi, "");
        if (line.startsWith("[test:"))
            line = line.canFind("] ") ? line[line.indexOf("] ") + 2 .. $] : line;
        if (line.startsWith("Summary: "))
            lines ~= line.replaceAll(time, "");
        // druntime's own runner, in a package that does not use this one.
        else if (line.endsWith(" modules passed unittests") || line.endsWith(" unittests failed")
            || line == "All unit tests have been run successfully.")
            lines ~= line.strip;
        else if (line.length > 2 && line[0] == ' ' && line[1] >= 0x80)
            lines ~= line.strip;
    }
    return lines.sort.release;
}

/// What differs between the graph's run of `pkg`'s tests and `dub test`'s;
/// null when they agree. `tests` counts the verdicts compared.
string equivalence(string pkg, out size_t tests)
{
    import std.process : execute;

    RunOptions o;
    o.jobs = std.process.environment.get("ORACLE2_JOBS", "0").to!uint;
    const cache = freshCache("o2");
    auto g = run(pkg, cache, o);
    scope (exit)
        if (exists(cache))
            rmdirRecurse(cache);
    if (g.error.length)
        return "the graph could not plan it: " ~ g.error;
    const d = execute(["dub", "test", "-q", "--skip-registry=all", ":" ~ pkg, "--", "--no-colors"], null,
        std.process.Config.none, size_t.max, root);
    // Each side's whole output, kept for a difference to be read later.
    if (const logs = std.process.environment.get("ORACLE2_LOGS", null))
    {
        mkdirRecurse(logs);
        write(buildPath(logs, pkg ~ ".graph.log"), g.log);
        write(buildPath(logs, pkg ~ ".dub.log"), d.output);
    }
    const graphLines = verdictLines(g.log), dubLines = verdictLines(d.output);
    tests = dubLines.length;
    if (!dubLines.length)
        return "dub test reported no verdict:" ~ tailOf(d.output);
    if ((g.exitCode == 0) != (d.status == 0))
        return text("the graph exited ", g.exitCode, " and dub test ", d.status, ":", tailOf(g.log), tailOf(d.output));
    if (graphLines != dubLines)
    {
        string why = "the verdicts differ:";
        foreach (l; graphLines)
            if (!dubLines.canFind(l))
                why ~= "\n    graph only: " ~ l;
        foreach (l; dubLines)
            if (!graphLines.canFind(l))
                why ~= "\n    dub only:   " ~ l;
        return why;
    }
    return null;
}

Verdict[] oracle2()
{
    import sparkles.build_primitives.dub_manifest : DubConfiguration;

    Verdict[] vs;
    void compare(string scenario, string pkg)
    {
        size_t n;
        const why = equivalence(pkg, n);
        vs ~= Verdict(scenario, why, text(n, " verdict lines and the exit status agree"));
    }

    // A test that inspects a dependency's version identifier.
    auto lv = Fixture.add("o2v", [
        "dub.sdl": recipeOf("o2v", null, null, ["ZzOracle2Dependency"]),
        "src/sparkles/zz_o2v/v.d": "module sparkles.zz_o2v.v;\n\nint v() { return 1; }\n",
    ]);
    auto tv = Fixture.add("o2w", [
        "dub.sdl": recipeOf("o2w", ["zz-oracle-o2v"]),
        "src/sparkles/zz_o2w/w.d": "module sparkles.zz_o2w.w;\n\nimport sparkles.zz_o2v.v;\n\n"
            ~ "@(\"o2.dependencyVersion\") unittest\n{\n    version (ZzOracle2Dependency) assert(v() == 1);\n"
            ~ "    else assert(0, \"the dependency's version identifier is not set\");\n}\n",
    ]);
    compare("a dependency's version identifier", tv.name);

    // A test that reads a string import.
    auto si = Fixture.add("o2s", [
        "dub.sdl": recipeOf("o2s", null, null, null, (ref DubManifest m) {
            m.stringImportPaths = [platformValues("views")];
        }),
        "views/greeting.txt": "hello\n",
        "src/sparkles/zz_o2s/s.d": "module sparkles.zz_o2s.s;\n\n"
            ~ "@(\"o2.stringImport\") unittest\n{\n    assert(import(\"greeting.txt\") == \"hello\\n\");\n}\n",
    ]);
    compare("a string import", si.name);

    // A test whose dependency is a sourceLibrary.
    auto sl = Fixture.add("o2l", [
        "dub.sdl": recipeOf("o2l", null, null, null, (ref DubManifest m) {
            m.configurations[0].targetType = "sourceLibrary";
        }),
        "src/sparkles/zz_o2l/l.d": "module sparkles.zz_o2l.l;\n\nint fromSource() { return 3; }\n",
    ]);
    auto ts = Fixture.add("o2m", [
        "dub.sdl": recipeOf("o2m", ["zz-oracle-o2l"]),
        "src/sparkles/zz_o2m/m.d": "module sparkles.zz_o2m.m;\n\nimport sparkles.zz_o2l.l;\n\n"
            ~ "@(\"o2.sourceLibrary\") unittest\n{\n    assert(fromSource() == 3);\n}\n",
    ]);
    compare("a sourceLibrary dependency", ts.name);

    // An application whose mainSourceFile is left out of its test root: a
    // test in it fails when it is compiled in.
    auto app = Fixture.add("o2a", [
        "dub.sdl": recipeOf("o2a", null, null, null, (ref DubManifest m) {
            m.configurations[0].targetType = "executable";
            m.mainSourceFile = "src/sparkles/zz_o2a/app.d";
        }),
        "src/sparkles/zz_o2a/app.d": "module sparkles.zz_o2a.app;\n\nimport sparkles.zz_o2a.lib;\n\n"
            ~ "void main() { cast(void) twice(1); }\n\n"
            ~ "@(\"o2.mainCompiledIn\") unittest\n{\n    assert(0, \"the main source file is in the test root\");\n}\n",
        "src/sparkles/zz_o2a/lib.d": "module sparkles.zz_o2a.lib;\n\nint twice(int x) => 2 * x;\n\n"
            ~ "@(\"o2.application\") unittest\n{\n    assert(twice(2) == 4);\n}\n",
    ]);
    compare("an application's mainSourceFile", app.name);
    return vs;
}

/// Oracle 2 over every package of the root recipe (`--only=2-all`): hours.
Verdict[] oracle2All()
{
    Verdict[] vs;
    import std.string : split;

    // ORACLE2_PACKAGES names the packages to compare; every package otherwise.
    const chosen = std.process.environment.get("ORACLE2_PACKAGES", "").split;
    foreach (ref s; decodeRecipe(readText(buildPath(root, "dub.sdl"))).subPackages)
    {
        const recipe = buildPath(root, s.path, "dub.sdl");
        if (s.isInline || !exists(recipe))
            continue;
        const name = decodeRecipe(readText(recipe)).name;
        if (chosen.length && !chosen.canFind(name))
            continue;
        if (!name.length || name.startsWith(fixturePrefix))
            continue;
        size_t n;
        const why = equivalence(name, n);
        writeln(why.length ? "FAIL " : "pass ", name, why.length ? ": " ~ why : "");
        std.stdio.stdout.flush();
        vs ~= Verdict(name, why, text(n, " verdict lines and the exit status agree"));
    }
    return vs;
}

// === Oracle 4: digest audit ===

Verdict[] oracle4()
{
    import core.time : days, hours;
    import sparkles.build_graph.store : hexOf;
    import std.datetime.systime : Clock, SysTime;
    import std.file : getTimes, setTimes;
    import sparkles.base.hash.blake3 : blake3;

    Verdict[] vs;
    enum libModule = "module sparkles.zz_o4l.d;\n\n// Read by the test's compile.\nint dep() { return 4; }\n";
    auto lib = Fixture.add("o4l", [
        "dub.sdl": recipeOf("o4l"),
        "src/sparkles/zz_o4l/d.d": libModule,
    ]);
    auto app = Fixture.add("o4t", [
        "dub.sdl": recipeOf("o4t", ["zz-oracle-o4l"]),
        "src/sparkles/zz_o4t/t.d": "module sparkles.zz_o4t.t;\n\nimport sparkles.zz_o4l.d;\n\n"
            ~ "unittest\n{\n    assert(dep() == 4);\n}\n",
    ]);
    const module_ = buildPath(lib.dir, "src/sparkles/zz_o4l/d.d");
    const relativeModule = module_[root.length + 1 .. $];
    {
        // BGK5 caches a digest only on the store's file system.
        static ulong deviceOf(string path)
        {
            import core.sys.posix.sys.stat : stat, stat_t;
            import std.string : toStringz;

            stat_t st;
            return (() @trusted => stat(path.toStringz, &st))() == 0 ? st.st_dev : ulong.max;
        }
        if (deviceOf(scratch) != deviceOf(root))
            return [Verdict("steps 1-5", text("not run: the scratch stores (", scratch, ") are on another file system "
                ~ "than the worktree, where BGK5 caches no digest; set ORACLE_SCRATCH to a directory beside it"), null)];
    }
    void dated(SysTime when) { setTimes(module_, when, when); }
    // The module rewritten to `content`, its modification time kept.
    void rewriteKeepingTime(string content)
    {
        SysTime accessed, modified;
        getTimes(module_, accessed, modified);
        write(module_, content);
        setTimes(module_, accessed, modified);
    }
    const sameSize = libModule.replace("Read by the test's", "Read by the tests'");
    assert(sameSize.length == libModule.length);
    scope (exit)
        if (exists(module_))
            write(module_, libModule);

    // Step 1: a rewrite that keeps the size and modification time, an hour
    // after the digest was recorded and within its granularity.
    foreach (age; ["an hour old", "just written"])
    {
        write(module_, libModule);
        if (age == "an hour old")
            dated(Clock.currTime - 1.hours);
        const cache = freshCache("o4");
        auto first = run(app.name, cache);
        rewriteKeepingTime(sameSize);
        auto second = run(app.name, cache);
        const compile = taskOf(first, lib.task("compile"));
        vs ~= Verdict("step 1, " ~ age, first.exitCode ? "the fixture failed:" ~ tailOf(first.log)
            : !executed(second, compile) ? "the rewritten module was not rehashed: its compile hit" : null,
            "a same-size rewrite with its modification time restored was rehashed, and its compile reran");
    }

    // Step 2: a digest cache hit, audited by rehashing every record.
    {
        write(module_, libModule);
        dated(Clock.currTime - 1.hours);
        const cache = freshCache("o4");
        auto first = run(app.name, cache);
        auto second = run(app.name, cache);
        const records = storeDir(cache, "digests");
        string wrong;
        size_t audited;
        foreach (name; records)
        {
            string path, digest;
            foreach (line; readText(buildPath(cache, "build", "v1", "digests", name)).lineSplitter)
            {
                if (line.startsWith("path "))
                    path = line[5 .. $].idup;
                if (line.startsWith("digest "))
                    digest = line[7 .. $].idup;
            }
            const file = buildPath(root, path);
            if (!exists(file))
                continue;
            ++audited;
            if (hexOf(blake3(cast(const(ubyte)[]) std.file.read(file))) != digest)
                wrong ~= " " ~ path;
        }
        vs ~= Verdict("step 2", second.exitCode ? "the second run failed:" ~ tailOf(second.log)
            : second.stats.executedTasks.any!(t => !t.startsWith("test:")) ? text("the second run rebuilt ", second.stats.executedTasks)
            : !records.canFind!(r => readText(buildPath(cache, "build", "v1", "digests", r)).canFind("path " ~ relativeModule ~ "\n"))
                ? "no digest record names the fixture's module"
            : wrong.length ? "records that disagree with a rehash:" ~ wrong : null,
            text("a second run hit through the digest cache, and rehashing its ", audited,
                " records matched every one"));
    }

    // Step 3: a store entry corrupted three ways.
    {
        write(module_, libModule);
        const cache = freshCache("o4");
        auto first = run(app.name, cache);
        const compile = taskOf(first, lib.task("compile"));
        const key = first.stats.resultKeys.get(compile, null);
        string object;
        foreach (name, bytes; outputsOf(cache, key))
            object = buildPath(cache, "build", "v1", "results", key, "out", name);
        string corrupt(string how)
        {
            import std.file : remove;

            auto bytes = cast(ubyte[]) std.file.read(object);
            if (how == "truncated")
                write(object, bytes[0 .. $ / 2]);
            else if (how == "deleted")
                remove(object);
            else
            {
                bytes[$ / 2] ^= 0xff;
                write(object, bytes);
            }
            return how;
        }
        foreach (how; ["truncated", "deleted"])
        {
            corrupt(how);
            auto r = run(app.name, cache);
            vs ~= Verdict("step 3, " ~ how, !executed(r, compile) ? "the lookup served the " ~ how ~ " output"
                : !storeDir(cache, "results").canFind(key) ? "the rebuilt result was not published again" : null,
                "the next lookup found the " ~ how ~ " output, removed the entry, and the compile rebuilt it");
        }
        corrupt("flipped");
        RunOptions none, every;
        none.hashSample = 0;
        every.hashSample = 1;
        auto unsampled = run(app.name, cache, none);
        auto sampled = run(app.name, cache, every);
        corrupt("flipped");
        string lines;
        const verified = storeOp(cache, "verify", lines);
        vs ~= Verdict("step 3, flipped", executed(unsampled, compile) ? "a lookup that rehashes no hit saw the flipped byte"
            : !executed(sampled, compile) ? "a lookup with the hash sample at one served the flipped output"
            : verified == 0 || !lines.canFind(key) ? "verification did not find the flipped output: " ~ lines : null,
            "a flipped byte of the same size passed a lookup that rehashes none, and was found, removed and rebuilt "
            ~ "by one that rehashes every hit, and by `ci cache verify`");
    }

    // Step 4: a modification time in the future is rehashed on every read and
    // reported. A file system whose clock is set apart is not available here.
    {
        write(module_, libModule);
        dated(Clock.currTime + 1.days);
        const cache = freshCache("o4");
        auto first = run(app.name, cache);
        auto second = run(app.name, cache);
        vs ~= Verdict("step 4, the future", !first.stats.futureTimes.canFind(relativeModule)
            || !second.stats.futureTimes.canFind(relativeModule) ? text("not reported in both runs: ",
                first.stats.futureTimes, " ", second.stats.futureTimes)
            : !storeDir(cache, "digests").all!(r => !readText(buildPath(cache, "build", "v1", "digests", r))
                .canFind("path " ~ relativeModule ~ "\n")) ? "its digest was cached" : null,
            "a module dated a day ahead was reported in both runs, and its digest never cached");
        write(module_, libModule);
    }
    vs ~= Verdict("step 4, a clock set apart",
        "not run: needs a file system whose clock is set apart from the host's (a network or offset FUSE mount)", null);

    // Step 5: edits while the compiler runs (BGK7). The test's compile is
    // wrapped to run `edit` after the compiler, before the action ends.
    const testCompile = app.task("compile");
    RunOptions editing(string edit, string[] replace = null)
    {
        RunOptions o;
        o.replaceTasks = replace;
        o.adjustExecution = (string task, ref ProcessAction pa) {
            if (!task.startsWith(testCompile))
                return;
            string digests;
            foreach (arg; pa.argv)
                if (arg.startsWith("--makedeps-digests="))
                    digests = arg["--makedeps-digests=".length .. $];
            pa.argv = [sh(), "-c", "\"$0\" \"$@\"; s=$?; DIGESTS='" ~ digests ~ "'; " ~ edit ~ "; exit $s"] ~ pa.argv;
        };
        return o;
    }
    const edited = libModule.replace("int dep()", "// edited\nint dep()");
    const editFile = buildPath(scratch, "o4-edited.d");
    write(editFile, edited);
    const rewrite = tool("cp") ~ " " ~ editFile ~ " " ~ module_;
    {
        write(module_, libModule);
        const cache = freshCache("o4");
        auto first = run(app.name, cache);
        const compile = taskOf(first, testCompile);
        const manifestsBefore = storeDir(cache, "manifests");
        auto during = run(app.name, cache, editing(rewrite, [compile]));
        const manifestsAfter = storeDir(cache, "manifests");
        const editedDigest = hexOf(blake3(cast(const(ubyte)[]) edited));
        const cachedEdit = storeDir(cache, "digests").any!(r => readText(buildPath(cache, "build", "v1", "digests", r))
            .canFind("digest " ~ editedDigest));
        auto next = run(app.name, cache);
        write(module_, libModule);
        auto reverted = run(app.name, cache);
        vs ~= Verdict("step 5, a predicted file changes",
            !during.log.canFind("unstable input: " ~ relativeModule) ? "no unstable input was reported:" ~ tailOf(during.log)
            : during.exitCode != 0 ? "the run did not use the outputs:" ~ tailOf(during.log)
            : (compile in during.stats.resultKeys) !is null ? "the unstable compile was published"
            : manifestsAfter != manifestsBefore ? "a manifest was recorded"
            : cachedEdit ? "the edited module's digest was cached"
            : !executed(next, compile) ? "the next run did not compile again"
            : reverted.stats.resultKeys.get(compile, null) != first.stats.resultKeys.get(compile, "") ? "after the revert, the compile was not served the first run's result"
            : null,
            "the run reported the unstable input and used the outputs, leaving no result, manifest or digest; the "
            ~ "next run compiled again, and after the revert the first run's result was served");
    }
    {
        write(module_, libModule);
        const cache = freshCache("o4");
        auto first = run(app.name, cache);
        const compile = taskOf(first, testCompile);
        const link = buildPath(scratch, "o4-hardlink.d");
        if (exists(link))
            std.file.remove(link);
        auto during = run(app.name, cache, editing(tool("ln") ~ " " ~ module_ ~ " " ~ link, [compile]));
        vs ~= Verdict("step 5, only the change time changes", during.log.canFind("unstable input")
            ? "a hard link alone was reported unstable" : (compile !in during.stats.resultKeys) ? "the result was not published" : null,
            "a hard link added to a predicted module during the compile was rehashed, and the result published");
    }
    {
        write(module_, libModule);
        const cache = freshCache("o4");
        auto during = run(app.name, cache, editing(rewrite));
        write(module_, libModule);
        vs ~= Verdict("step 5, a newly read file changes", !during.log.canFind("unstable input: " ~ relativeModule)
            ? "a module no manifest listed, edited after the compiler read it, did not conflict" : null,
            "a module no earlier manifest listed, rewritten after the compiler read it, conflicted");
    }
    vs ~= Verdict("step 5, the clock", "not run: needs a file system whose clock runs behind the host's", null);
    {
        write(module_, libModule);
        const cache = freshCache("o4");
        // The compiler reports a digest of zeros for the module: every stat
        // proxy is unchanged.
        auto during = run(app.name, cache, editing(tool("sed") ~ " -i 's/^[0-9a-f]\\{64\\}\\(  .*zz_o4l\\/d\\.d\\)$/"
            ~ "0000000000000000000000000000000000000000000000000000000000000000\\1/' \"$DIGESTS\""));
        vs ~= Verdict("step 5, compiler digests", !during.log.canFind("unstable input: " ~ relativeModule)
            ? "a compiler digest other than the file's did not conflict:" ~ tailOf(during.log) : null,
            "a compiler that reported another digest for a module conflicted, with every stat proxy unchanged");
    }
    {
        // The module rewritten, alternately, during every run.
        const cache = freshCache("o4");
        const original = buildPath(scratch, "o4-original.d");
        write(original, libModule);
        string why;
        foreach (i; 0 .. 3)
        {
            write(module_, i % 2 ? edited : libModule);
            auto r = run(app.name, cache, editing(tool("cp") ~ " " ~ (i % 2 ? original : editFile) ~ " " ~ module_));
            const compiles = r.stats.executedTasks.count!(t => t.startsWith(testCompile));
            if (compiles != 1)
                why ~= text(" run ", i, " ran the compile ", compiles, " times;");
        }
        write(module_, libModule);
        vs ~= Verdict("step 5, no loop", why, "with the module rewritten during every run, each ran the compile once; "
            ~ "a watch-mode run is not in E3");
    }
    return vs;
}

// === Oracle 3: manifest completeness, its mutation scenarios ===

Verdict[] oracle3()
{
    Verdict[] vs;
    // Runs `pkg`'s test root, applies `mutate`, and runs it again: whether
    // the compile of `pkg` kept its result key, or why it could not tell.
    string changedWhere;
    string keyKept(ref Fixture pkg, void delegate() mutate, out bool kept)
    {
        const cache = freshCache("o3");
        auto before = run(pkg.name, cache);
        if (before.exitCode != 0)
            return "the fixture failed:" ~ tailOf(before.log);
        mutate();
        auto after = run(pkg.name, cache);
        if (after.exitCode != 0)
            return "the mutated fixture failed:" ~ tailOf(after.log);
        const compile = taskOf(before, pkg.task("compile"));
        kept = before.stats.resultKeys.get(compile, "a") == after.stats.resultKeys.get(compile, "b");
        changedWhere = before.stats.declaredKeys.get(compile, "a") != after.stats.declaredKeys.get(compile, "b")
            ? "its declared key" : "its manifest";
        return null;
    }
    void expect(string scenario, ref Fixture pkg, void delegate() mutate, bool changes)
    {
        bool kept;
        const why = keyKept(pkg, mutate, kept);
        vs ~= Verdict(scenario, why.length ? why
            : kept == changes ? (changes ? "the compile kept its result key" : "the compile's result key changed, through " ~ changedWhere) : null,
            changes ? "the compile's result key changed" : "the compile kept its result key");
    }

    // A dependency with a module the test reads and one it does not.
    auto lib = Fixture.add("o3l", [
        "dub.sdl": recipeOf("o3l"),
        "src/sparkles/zz_o3l/read.d": "module sparkles.zz_o3l.read;\n\nint readValue() { return 1; }\n",
        "src/sparkles/zz_o3l/unread.d": "module sparkles.zz_o3l.unread;\n\nint unreadValue() { return 2; }\n",
    ]);
    // The test: a string import, a module `m` that `-Ia -Ib` resolve to
    // `b/m.d`, a module `q` resolved to `b/q.d`, and a failed probe of a
    // module `opt`. ImportC sources are in a package of their own: a compile
    // with them keys on every file under its include roots, the D ones
    // included (BGK2, BGK6), so an unread module there changes its key.
    auto t = Fixture.add("o3t", [
        "dub.sdl": recipeOf("o3t", ["zz-oracle-o3l"], null, null, (ref DubManifest m) {
            m.importPaths = [platformValues("src", "a", "b")];
            m.stringImportPaths = [platformValues("views")];
        }),
        "views/data.txt": "one\n",
        "a/.keep": "",
        "b/m.d": "module m;\n\nenum mValue = 1;\n",
        "b/q.d": "module q;\n\nenum qValue = 1;\n",
        "src/sparkles/zz_o3t/t.d": "module sparkles.zz_o3t.t;\n\nimport m : mValue;\nimport q : qValue;\n"
            ~ "import sparkles.zz_o3l.read;\n\n"
            ~ "enum optional = __traits(compiles, { import opt; });\n\n"
            ~ "unittest\n{\n    assert(readValue() == 1 && mValue == 1 && qValue == 1);\n"
            ~ "    assert(import(\"data.txt\").length);\n    static if (optional) {}\n}\n",
    ]);
    expect("a file in the manifest is edited", t, {
        lib.put("src/sparkles/zz_o3l/read.d", "module sparkles.zz_o3l.read;\n\nint readValue() { return 1; } // edited\n");
    }, true);
    expect("a dependency's file the compile did not read is edited", t, {
        lib.put("src/sparkles/zz_o3l/unread.d", "module sparkles.zz_o3l.unread;\n\nint unreadValue() { return 3; }\n");
    }, false);
    expect("a string import is edited", t, { t.put("views/data.txt", "two\n"); }, true);
    auto c = Fixture.add("o3c", [
        "dub.sdl": recipeOf("o3c", null, ["c"]),
        "c/top.h": "#include \"middle.h\"\n",
        "c/middle.h": "#include \"deep.h\"\n",
        "c/deep.h": "#define ZZ_DEEP 1\n",
        // ImportC turns the macro into a constant: nothing to link.
        "src/sparkles/zz_o3c/headers.c": "#include \"top.h\"\n",
        "src/sparkles/zz_o3c/t.d": "module sparkles.zz_o3c.t;\n\nimport sparkles.zz_o3c.headers;\n\n"
            ~ "unittest\n{\n    assert(ZZ_DEEP == 1);\n}\n",
    ]);
    expect("an ImportC header two includes deep is edited", c, { c.put("c/deep.h", "#define ZZ_DEEP 1 /* edited */\n"); }, true);
    expect("a/m.d is created where -Ia -Ib resolved m to b/m.d", t, { t.put("a/m.d", "module m;\n\nenum mValue = 1;\n"); }, true);
    expect("a .di is created beside a .d", t, { t.put("b/q.di", "module q;\n\nenum qValue = 1;\n"); }, true);
    expect("a package.d is created in an earlier root", t, { t.put("a/q/package.d", "module q;\n\nenum qValue = 1;\n"); }, true);
    expect("the module a failed __traits(compiles) probe looked for is created", t, {
        t.put("b/opt.d", "module opt;\n");
    }, true);
    return vs;
}

// === Oracle 21: incremental equals clean ===

/// How the incremental run `inc` (on the store beneath `incCache`) differs
/// from the cold run `cold` (beneath `coldCache`): exit status, test
/// verdicts, compiler diagnostics, result keys and every output's bytes.
/// Null when they agree.
string differsFromCold(ref const GraphRun inc, string incCache, ref const GraphRun cold, string coldCache)
{
    if (inc.error.length || cold.error.length)
        return inc.error != cold.error ? "one could not plan: " ~ inc.error ~ " / " ~ cold.error : null;
    if (inc.exitCode != cold.exitCode)
        return text("the incremental run exited ", inc.exitCode, ", the cold one ", cold.exitCode);
    if (verdictLines(inc.log) != verdictLines(cold.log))
        return "the test verdicts differ";
    if (errorLines(inc.log).sort.release != errorLines(cold.log).sort.release)
        return "the compiler diagnostics differ";
    string why;
    foreach (task, key; cold.stats.resultKeys)
    {
        const mine = inc.stats.resultKeys.get(task, null);
        if (mine != key)
            why ~= " " ~ task ~ (mine.length ? "'s result key differs;" : " has no incremental result;");
        else if (outputsOf(incCache, key) != outputsOf(coldCache, key))
            why ~= " " ~ task ~ "'s outputs differ;";
    }
    foreach (task, _; inc.stats.resultKeys)
        if (task !in cold.stats.resultKeys)
            why ~= " " ~ task ~ " has no cold result;";
    return why;
}

/// The step-2 precision check of the incremental run `inc` against every
/// result key the store held before it (`known`): an action that executed
/// had a key the store did not hold, and one whose key it held was reused.
string imprecision(ref const GraphRun inc, const bool[string] known)
{
    string why;
    foreach (task, key; inc.stats.resultKeys)
    {
        if (task.startsWith("test:"))
            continue;
        const ran = inc.stats.executedTasks.canFind(task);
        if (ran && (key in known) !is null)
            why ~= " " ~ task ~ " executed under a key the store held;";
    }
    return why;
}

/// Oracle 21's step 3 over the fixture `pkg` and its dependency `lib`: the
/// edit sequence `seed` draws, each step built incrementally and cold.
string editSequence(uint seed, ref Fixture pkg, ref Fixture lib, size_t steps, out string[] applied)
{
    import std.algorithm : countUntil;
    import std.random : Random, uniform;

    auto rng = Random(seed);
    const cache = freshCache("o21");
    bool[string] known;
    string[string] files; // what each edited file held before its last edit, for a revert
    string other;
    scope (exit)
        if (other.length)
            removeWorktree(other);
    static immutable kinds = ["edit a module", "create at an absent candidate", "create a .di", "create a package.d",
        "edit a string import", "delete a file", "revert an edit", "switch worktree"];
    foreach (i; 0 .. steps + 1)
    {
        string at = root;
        if (i > 0)
        {
            const kind = kinds[uniform(0, kinds.length, rng)];
            applied ~= kind;
            const n = uniform(0, 1000, rng);
            final switch (kinds.countUntil(kind))
            {
                case 0:
                    files["src/sparkles/zz_o21l/l.d"] = readText(buildPath(lib.dir, "src/sparkles/zz_o21l/l.d"));
                    lib.put("src/sparkles/zz_o21l/l.d", text("module sparkles.zz_o21l.l;\n\nint value() { return ", n,
                        "; }\n"));
                    break;
                case 1:
                    pkg.put("a/m.d", text("module m;\n\nenum mValue = ", n, ";\n"));
                    break;
                case 2:
                    pkg.put("b/m.di", text("module m;\n\nenum mValue = ", n, ";\n"));
                    break;
                case 3:
                    pkg.put("a/q/package.d", text("module q;\n\nenum qValue = ", n, ";\n"));
                    break;
                case 4:
                    pkg.put("views/data.txt", text(n, "\n"));
                    break;
                case 5:
                    foreach (victim; ["a/m.d", "b/m.di", "a/q/package.d"])
                        if (exists(buildPath(pkg.dir, victim)))
                        {
                            std.file.remove(buildPath(pkg.dir, victim));
                            break;
                        }
                    break;
                case 6:
                    foreach (path, before; files)
                        lib.put(path, before);
                    files = null;
                    break;
                case 7:
                    if (!other.length)
                    {
                        other = secondWorktree();
                        copyFixture(lib, other);
                        copyFixture(pkg, other);
                    }
                    break;
            }
            // A switch builds the second worktree as it was copied; every other
            // step builds this one.
            if (kind == "switch worktree")
                at = other;
        }
        auto inc = run(pkg.name, cache, RunOptions.init, at);
        const coldCache = freshCache("o21");
        auto cold = run(pkg.name, coldCache, RunOptions.init, at);
        const step = text("seed ", seed, ", step ", i, applied.length ? " (" ~ applied[$ - 1] ~ ")" : "", ": ");
        const differs = differsFromCold(inc, cache, cold, coldCache);
        rmdirRecurse(coldCache);
        if (differs.length)
            return step ~ differs;
        if (const why = imprecision(inc, known))
            return step ~ why;
        foreach (_, key; inc.stats.resultKeys)
            known[key] = true;
    }
    return null;
}

Verdict[] oracle21()
{
    import sparkles.build_graph.execute : dropAbsentCandidates;

    Verdict[] vs;
    auto lib = Fixture.add("o21l", [
        "dub.sdl": recipeOf("o21l"),
        "src/sparkles/zz_o21l/l.d": "module sparkles.zz_o21l.l;\n\nint value() { return 0; }\n",
    ]);
    enum testModule = "module sparkles.zz_o21t.t;\n\nimport m : mValue;\nimport q : qValue;\nimport sparkles.zz_o21l.l;\n\n"
        ~ "unittest\n{\n    assert(value() >= 0 && mValue >= 0 && qValue >= 0);\n    assert(import(\"data.txt\").length);\n}\n";
    auto t = Fixture.add("o21t", [
        "dub.sdl": recipeOf("o21t", ["zz-oracle-o21l"], null, null, (ref DubManifest m) {
            m.importPaths = [platformValues("src", "a", "b")];
            m.stringImportPaths = [platformValues("views")];
        }),
        "views/data.txt": "0\n",
        "a/.keep": "",
        "b/m.d": "module m;\n\nenum mValue = 0;\n",
        "b/q.d": "module q;\n\nenum qValue = 0;\n",
        "src/sparkles/zz_o21t/t.d": testModule,
    ]);
    // The fixture as it starts, restored before each sequence.
    void reset()
    {
        foreach (extra; ["a/m.d", "b/m.di", "a/q/package.d"])
            if (exists(buildPath(t.dir, extra)))
                std.file.remove(buildPath(t.dir, extra));
        if (exists(buildPath(t.dir, "a/q")))
            rmdirRecurse(buildPath(t.dir, "a/q"));
        t.put("views/data.txt", "0\n");
        lib.put("src/sparkles/zz_o21l/l.d", "module sparkles.zz_o21l.l;\n\nint value() { return 0; }\n");
    }
    foreach (seed; [1u, 2u, 3u])
    {
        reset();
        string[] applied;
        const why = editSequence(seed, t, lib, 8, applied);
        vs ~= Verdict(text("step 3, seed ", seed), why.length ? why ~ text(" after ", applied) : null,
            text("8 edits (", applied.join(", "), ") each built incrementally as a cold build did, executing only "
                ~ "the actions whose keys the store did not hold"));
    }

    // The revert check: without absent candidates, a file created at one
    // goes unseen, and the incremental build differs from the cold one.
    {
        reset();
        dropAbsentCandidates = true;
        scope (exit)
            dropAbsentCandidates = false;
        const cache = freshCache("o21");
        auto first = run(t.name, cache);
        t.put("a/m.d", "module m;\n\nenum mValue = 7;\n");
        auto inc = run(t.name, cache);
        const coldCache = freshCache("o21");
        auto cold = run(t.name, coldCache);
        const compile = taskOf(first, t.task("compile"));
        vs ~= Verdict("revert check", first.exitCode ? "the fixture failed:" ~ tailOf(first.log)
            : inc.stats.resultKeys.get(compile, "a") != first.stats.resultKeys.get(compile, "b")
                ? "without absent candidates, the created file still changed the compile's key"
            : !differsFromCold(inc, cache, cold, coldCache).length ? "the oracle did not tell the incremental build from the cold one" : null,
            "without absent candidates, a file created at one left the compile's key unchanged, as a cold build "
            ~ "did not: the oracle sees the difference");
        reset();
    }
    vs ~= Verdict("steps 1-2", "run separately: --only=21-replay replays commits of main", null);
    return vs;
}

/// Oracle 21's steps 1 and 2 (`--only=21-replay`, hours): the last N commits
/// of `origin/main` (`ORACLE21_COMMITS`, 50 by default), each built
/// incrementally on the store the one before left and cold, for the packages
/// `ORACLE21_PACKAGES` names (`versions build-graph` by default).
Verdict[] oracle21Replay()
{
    import std.string : split, strip;
    import sparkles.build_primitives.git_env : runGit;

    Verdict[] vs;
    const n = std.process.environment.get("ORACLE21_COMMITS", "50").to!size_t;
    const packages = std.process.environment.get("ORACLE21_PACKAGES", "versions build-graph").split;
    const listed = runGit(["rev-list", "--first-parent", "-n", text(n), "origin/main"], root);
    assert(listed.status == 0, listed.output);
    auto commits = listed.output.strip.split("\n");
    {
        import std.algorithm.mutation : reverse;

        reverse(commits);
    }
    const tree = secondWorktree();
    scope (exit)
        removeWorktree(tree);
    const cache = freshCache("o21r");
    bool[string] known;
    foreach (k, commit; commits)
    {
        const co = runGit(["checkout", "--quiet", "--detach", commit], tree);
        if (co.status != 0)
        {
            vs ~= Verdict(commit[0 .. 12], "cannot check it out: " ~ co.output, null);
            continue;
        }
        string why;
        foreach (pkg; packages)
        {
            auto inc = run(pkg, cache, RunOptions.init, tree);
            const coldCache = freshCache("o21r");
            auto cold = run(pkg, coldCache, RunOptions.init, tree);
            if (const d = differsFromCold(inc, cache, cold, coldCache))
                why ~= " " ~ pkg ~ ":" ~ d;
            else if (k > 0)
                if (const p = imprecision(inc, known))
                    why ~= " " ~ pkg ~ ":" ~ p;
            foreach (_, key; inc.stats.resultKeys)
                known[key] = true;
            rmdirRecurse(coldCache);
        }
        writeln(why.length ? "FAIL " : "pass ", commit[0 .. 12], why);
        std.stdio.stdout.flush();
        vs ~= Verdict(commit[0 .. 12], why, text(packages, " built incrementally as cold, precisely"));
    }
    return vs;
}
