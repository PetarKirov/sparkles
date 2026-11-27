#!/usr/bin/env dub
/+ dub.sdl:
    name "plan_graph"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:build-graph" path="../../.."
    dependency "sparkles:unittest-layout" path="../../.."
    dependency "sparkles:d-source" path="../../.."
    dependency "sparkles:test-runner-core" path="../../.."
    // ci's statement of the workspace inputs, for the CIC5 check.
    // (single-file packages take no sourceFiles: `-i=` compiles the import)
    dflags "-I=$PACKAGE_DIR/../src" "-i=repository_inputs" "-i=graph_driver" "-i=plan_reuse" "-i=test_leg" platform="ldc"

    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
The build graph's test-only planner (build-graph PLAN, E2's gate): plans the
repository's test selection and prints its action graph, or checks it.

    dub run --single apps/ci/tools/plan-graph.d -- [--check] [--reads] [<root>]

It resolves every package's test root, plans the variants (with the layout
lint, `sparkles:unittest-layout`, and libraries through `pkg-config`) and
lowers them to actions. Planning reads through a tree that serves only
BGF2's roots: the worktree and the pinned registry sources. Without
`--check` it prints the graph: one block per action, sorted by id, then the
edges; `--reads` adds the read set. With `--check` it verifies E2's gate
instead and prints a verdict per oracle:

$(LIST
    * the graph is deterministic: two plans print the same bytes, and a
        coverage attempt's plain fallback is the plain test's compile
        (oracle 14);
    * one compile per variant (BGA2);
    * the layout lint's scenarios fail planning by place, and pass inside
        `unittest` blocks (oracle 8's planning scenarios);
    * every file planning opened, and every lookup that failed, is in the
        read set, under a system-call trace (oracle 20 step 1);
    * an edit to a file outside the read set leaves the plan as it was
        (oracle 20 step 2);
    * every read outside a package directory is one of `ci`'s workspace
        inputs, and leaving one of them out fails the check (oracle 20 step 3,
        CIC5);
    * no planning module touches the file system but through the VFS, its
        own lookups from the process's root open only BGF2's roots, a fixture
        plans the same in memory and on disk, and a fixture's links are
        recorded or refused (oracle 24 steps 1–4).
)

`--run=<package> [--into=<dir>] [--cache=<dir> | --no-store]` is E3's local
execution by hand: it plans that package's test root and runs its actions on
the task-DAG executor, with the toolchain from `PATH` named by absolute path
(`build_graph/execute.d`), reusing and publishing results in the store beneath the
cache directory (`$XDG_CACHE_HOME/sparkles` by default, §6), and prints what
it executed and what it reused.
`--test-timeout=<n>s|m|h` replaces a test's 20-minute limit (BGA12); `0` sets
none.

Needs the dev shell's `SPARKLES_DUB_SOURCES` for the registry packages, and
`strace` (the dev shell's, on Linux) for the trace steps. `--trace-target=F`
is the traced planner: it plans once between two marker lookups and writes
its read set to `F`.
*/
module plan_graph;

import core.time : Duration, hours, minutes, seconds;
import std.algorithm : canFind, endsWith, filter, map, sort, startsWith;
import std.array : array, join, replace, split;
import std.conv : octal, text, to;
import std.file : dirEntries, readText, SpanMode;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.process : environment;
import std.string : indexOf;
import std.stdio : stderr, writeln;
import std.sumtype : match;
import std.typecons : Nullable;

import sparkles.build_graph.actions : ActionGraph, ActionKind, CoverageAttempt, TestProgram, Tools,
    planActions, taskNodes;
import sparkles.build_graph.variants : LayoutCheck, PlanError, PlanOptions, Role, ToolchainIdentity,
    VariantPlan, planVariants;
import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;
import sparkles.build_primitives.resolve.configure : Resolution, ResolveRequest, resolve;
import sparkles.build_primitives.resolve.libraries : PkgConfigDriver, RecordingPkgConfig, SystemPkgConfig;
import sparkles.build_primitives.resolve.platform : BuildPlatform;
import sparkles.build_primitives.resolve.registry : nixRegistrySources, readDubLocks;
import sparkles.build_primitives.resolve.tree : ResolveTree, memoryTree, rootedTree, systemTree;
import sparkles.build_primitives.task.action : InProcessAction, InertAction, ProcessAction;
import sparkles.build_primitives.workspace.discovery : ReadKind, ReadSet, readWorkspaceAt;
import sparkles.build_primitives.workspace.package_graph : RecipeRole, buildPackageGraph;
import sparkles.unittest_layout.lint : checkLayout;

import graph_driver;

int main(string[] args)
{
    const check = args.canFind("--check");
    const showReads = args.canFind("--reads");
    const traceTarget = args.filter!(a => a.startsWith("--trace-target=")).array;
    const positional = args[1 .. $].filter!(a => !a.startsWith("--")).array;
    const root = buildNormalizedPath(absolutePath(positional.length ? positional[0] : "."));

    if (traceTarget.length)
        return tracedPlan(root, traceTarget[0]["--trace-target=".length .. $]);
    if (args.canFind("--fetch-sources"))
    {
        // BGR4: the locked sources, fetched into the store, in Nix's place.
        const cacheArg = args.filter!(a => a.startsWith("--cache=")).array;
        const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
        fetchedSources = fetchSources(root, cacheArg.length
            ? absolutePath(cacheArg[0]["--cache=".length .. $]) : buildPath(xdg, "sparkles"));
        if (fetchedSources is null)
            return 2;
    }
    const cacheOps = args.filter!(a => a.startsWith("--cache-op=")).array;
    if (cacheOps.length)
    {
        const cacheArg = args.filter!(a => a.startsWith("--cache=")).array;
        const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
        return cacheOp(cacheArg.length ? absolutePath(cacheArg[0]["--cache=".length .. $]) : buildPath(xdg, "sparkles"),
            cacheOps[0]["--cache-op=".length .. $]);
    }
    const runOnly = args.filter!(a => a.startsWith("--run=")).array;
    if (runOnly.length)
    {
        // The store lives in the user's cache (BGS1) unless `--cache` names
        // another, and `--no-store` runs without one; a run directory lies
        // beneath it unless `--into` names one elsewhere.
        const into = args.filter!(a => a.startsWith("--into=")).array;
        const cacheArg = args.filter!(a => a.startsWith("--cache=")).array;
        const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
        const cache = args.canFind("--no-store") ? null
            : cacheArg.length ? absolutePath(cacheArg[0]["--cache=".length .. $]) : buildPath(xdg, "sparkles");
        import std.datetime.systime : Clock;
        import std.process : thisProcessID;

        const runDir = into.length ? absolutePath(into[0]["--into=".length .. $])
            : cache.length ? buildPath(cache, "runs", text(Clock.currTime.toUnixTime, "-", thisProcessID))
            : buildPath(root, "build", "graph-run");
        // `--run=all` runs every package's test root; `--jobs=N` caps the
        // weight running at once (the default: one per processor).
        const name = runOnly[0]["--run=".length .. $];
        const jobs = args.filter!(a => a.startsWith("--jobs=")).array;
        runJobs = jobs.length ? jobs[0]["--jobs=".length .. $].to!uint : 0;
        traceCompiles = args.canFind("--trace-compiles");
        runnerCore = args.canFind("--runner-core");
        noDependencyOutput = args.canFind("--no-dependency-output");
        foreach (a; args.filter!(a => a.startsWith("--test-timeout=")))
        {
            const t = parseLimit(a["--test-timeout=".length .. $]);
            if (t.isNull)
            {
                stderr.writeln("plan-graph: ", "--test-timeout takes <n>s, <n>m, <n>h or 0, not " ~ a);
                return 2;
            }
            testTimeout = t.get;
        }
        oracle3Only = args.canFind("--oracle3-only");
        return runPackage(root, name == "all" ? null : name, runDir, cache, args.canFind("--check-determinism"),
            args.canFind("--confine-tests") ? Confinement.tests : args.canFind("--confine") ? Confinement.builds
            : Confinement.none);
    }

    auto first = planRepository(root);
    if (first.error.length)
    {
        stderr.writeln("plan-graph: ", first.error);
        return 1;
    }
    if (!check)
    {
        writeln(first.text);
        if (showReads)
            foreach (e; first.reads.entries)
                writeln("read ", e.kind, " ", e.path, e.names.length ? " " ~ e.names : "", e.found ? "" : " (absent)");
        return 0;
    }

    bool ok = true;
    void verdict(string oracle, bool passed, string detail)
    {
        writeln(passed ? "pass " : "FAIL ", oracle, ": ", detail);
        ok &= passed;
    }

    // Oracle 14: the same request planned twice prints the same graph.
    const second = planRepository(root);
    verdict("oracle 14 (deterministic graph)", second.text == first.text,
        text(first.graph.actions.length, " actions, ", first.graph.edges.length, " edges"));
    const fallback = coverageFallback(root);
    verdict("oracle 14 (edges are not inputs)", fallback.length == 0,
        fallback.length ? fallback : "a coverage attempt's plain compile is the plain test's");

    // BGA2: one compile per variant.
    size_t compiles;
    foreach (ref a; first.graph.actions)
        compiles += a.kind == ActionKind.compile;
    verdict("BGA2 (one compile per variant)", compiles == first.plan.variants.length,
        text(first.requests, " test roots, ", first.targets, " targets, ", first.plan.variants.length,
            " variants, ", compiles, " compiles"));

    // Oracle 8's planning scenarios.
    const o8 = oracle8();
    verdict("oracle 8 (layout lint through planning)", o8.length == 0, o8.length ? o8 : "seven scenarios");

    // Oracle 20 step 1 and oracle 24 step 2: the system-call trace.
    const trace = traceChecks(root);
    verdict("oracle 20 step 1 (trace within the read set)", trace.readSet.length == 0,
        trace.readSet.length ? trace.readSet : trace.summary);
    verdict("oracle 24 step 2 (lookups from the root open BGF2's roots)", trace.roots.length == 0,
        trace.roots.length ? trace.roots : trace.rootsSummary);

    // Oracle 20 step 2: edits outside the read set change nothing.
    const edits = editSample(root, first);
    verdict("oracle 20 step 2 (edits outside the read set)", edits.failure.length == 0,
        edits.failure.length ? edits.failure : edits.summary);

    // Oracle 20 step 3 (CIC5): reads outside package directories are
    // workspace inputs.
    const cic5 = checkCic5(root, first);
    verdict("oracle 20 step 3 (CIC5)", cic5.length == 0,
        cic5.length ? cic5 : text(first.reads.entries.length, " reads, each inside a package or a workspace input"));
    const removed = checkCic5(root, first, without: "nix/ci-dub-lock.json");
    verdict("oracle 20 step 3 (CIC5 without an invalidator)", removed.canFind("nix/ci-dub-lock.json"),
        removed.canFind("nix/ci-dub-lock.json") ? "leaving out nix/ci-dub-lock.json fails the check, naming it"
            : "leaving out nix/ci-dub-lock.json did not fail the check: " ~ removed);

    // Oracle 24 steps 1, 3 and 4.
    const audit = sourceAudit(root);
    verdict("oracle 24 step 1 (source audit)", audit.length == 0, audit.length ? audit : "planning modules use the VFS only");
    const backends = backendsAgree();
    verdict("oracle 24 step 3 (memory and disk agree)", backends.length == 0,
        backends.length ? backends : "a fixture plans the same in memory and on disk");
    const links = linkScenarios();
    verdict("oracle 24 step 4 (links)", links.length == 0,
        links.length ? links : "a link is recorded with its target, and an escaping one fails naming it");

    writeln(first.plan.layout.length, " layout findings in registry packages; ",
        first.plan.conditions.length, " string-built conditions reported");
    return ok ? 0 : 1;
}

// The traced planner: plans once and writes its read set and roots.
int tracedPlan(string root, string readsFile)
{
    import std.file : write;
    import core.memory : GC;
    import core.sys.posix.time : tzset;

    // The runtime's own reads, made before planning starts: the collector
    // counts the processors when it first collects, and the C library reads
    // the time zone when the DMD frontend first asks the date (D59).
    GC.collect();
    tzset();

    auto p = planRepository(root, markers: true);
    if (p.error.length)
    {
        stderr.writeln("plan-graph: ", p.error);
        return 1;
    }
    string lines;
    foreach (r; p.roots)
        lines ~= "root\t" ~ r ~ "\n";
    foreach (e; p.reads.entries)
        lines ~= text(e.kind, "\t", e.found, "\t", e.path, "\t", e.names, "\n");
    write(readsFile, lines);
    return 0;
}

// vector, so one result serves both.
string coverageFallback(string root)
{
    import sparkles.build_primitives.task.model : EdgeCondition;

    const d = driverEnvironment();
    auto tree = rootedTree([root, d.sources]);
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")], tree);
    const registry = nixRegistrySources(locked.value, d.sources, tree);
    Resolution request(string buildType)
    {
        auto q = ResolveRequest(directory: root, subPackage: ":versions", buildType: buildType,
            platform: platform, testRoot: true);
        foreach (n, s; registry.value)
            q.registry[n] = s;
        auto r = resolve(q, tree);
        assert(r.hasValue, r.hasError ? r.error.message : null);
        return r.value;
    }
    ActionGraph graphOf(const Resolution[] rs, const CoverageAttempt[] attempts)
    {
        auto plan = planVariants(rs, PlanOptions(ToolchainIdentity("ldc", "dev-shell"), layoutLint(),
            registry.value.keys), tree);
        assert(plan.hasValue, plan.hasError ? text(plan.error) : null);
        auto g = planActions(plan.value, rs, root, Tools.init, attempts);
        assert(g.hasValue, g.hasError ? g.error.message : null);
        return g.value;
    }

    const plain = request("unittest");
    const attempt = graphOf([request("unittest-cov"), plain], [CoverageAttempt(0, 1)]);
    const alone = graphOf([plain], null);

    string failures;
    size_t fallbacks;
    foreach (ref e; attempt.edges)
    {
        if (e.condition != EdgeCondition.onFailure)
            continue;
        ++fallbacks;
        const compile = attempt.find(e.dependent);
        const same = alone.find(e.dependent);
        if (compile is null || compile.kind != ActionKind.compile)
            failures ~= " the fallback edge does not lead to a compile;";
        else if (same is null)
            failures ~= " the plain test's graph has no " ~ e.dependent.text ~ ";";
        else if (same.action != compile.action || same.outputs != compile.outputs)
            failures ~= " the plain compile differs between the graphs;";
        else if (compile.provisional)
            failures ~= " the plain compile is provisional;";
    }
    if (fallbacks != 1)
        failures ~= text(" ", fallbacks, " fallback edges, not one;");
    size_t provisional;
    foreach (ref a; attempt.actions)
        provisional += a.provisional;
    if (provisional == 0)
        failures ~= " no coverage action is provisional;";
    return failures;
}

// Oracle 8 through planning, with the real lint: each hazard in a fixture
// library fails the plan at its place; inside a `unittest` block it plans.
string oracle8()
{
    static immutable string[2][] hazards = [
        ["struct S {\nversion (unittest) int x;\n}\n", "a field"],
        ["class C {\nversion (unittest) void f() {}\n}\n", "a virtual method"],
        ["struct S {\nversion (unittest) ~this() {}\n}\n", "a destructor"],
        ["version (unittest)\nenum E { a }\n", "a public enum"],
        ["void f(T)() {\nversion (unittest) {}\n}\n", "a `version (unittest)` inside a template"],
        ["version (unittest)\nimport sparkles.test_utils;\n", "an import of `sparkles.test_utils`, which the library does not depend on"],
    ];
    string failures;
    foreach (h; hazards)
    {
        auto tree = fixture("module leaf;\n" ~ h[0]);
        const plan = planFixture(tree);
        if (!plan.hasError || plan.error.file != "/r/leaf/source/leaf.d" || plan.error.line != 3
            || !plan.error.message.canFind(h[1]))
            failures ~= text(" `", h[1], "` was not reported at leaf.d:3;");
    }
    auto inside = fixture("module leaf;\nunittest {\nstruct S { int x; ~this() {} }\nenum E { a }\n}\n");
    if (planFixture(inside).hasError)
        failures ~= " the hazards inside a unittest block failed the plan;";
    return failures;
}

ResolveTree fixture(string leaf)
{
    return memoryTree([
        "/r/dub.sdl": "name \"r\"\nsubPackage \"t1\"\nsubPackage \"leaf\"\n",
        "/r/t1/dub.sdl": `name "t1"
dependency "r:leaf" path=".."
configuration "library" {
}
configuration "unittest" {
}
`,
        "/r/t1/source/t1.d": "module t1;\n",
        "/r/leaf/dub.sdl": "name \"leaf\"\n",
        "/r/leaf/source/leaf.d": leaf,
    ]);
}

auto planFixture(ResolveTree tree, string at = "/r")
{
    auto r = resolve(ResolveRequest(directory: at, subPackage: ":t1", buildType: "unittest",
        platform: platform, testRoot: true), tree);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    return planVariants([r.value], PlanOptions(ToolchainIdentity("ldc", "fixture"), layoutLint()), tree);
}
struct TraceResult
{
    string readSet, summary, roots, rootsSummary;
}

/*
Oracle 20 step 1 and oracle 24 step 2: plans under
`strace -f -y -e trace=%file`, between the traced planner's two marker
lookups.

- Step 1: every lookup of the planner's own threads, found or not, is in
    the read set: an entry, a directory an entry lies beneath, a directory a
    listing resolved, or one of the roots. The `pkg-config` processes planning
    starts are left out: each query is recorded with its arguments, answer and
    environment instead (D59).
- Oracle 24 step 2 (the main thread, as a trace without `-f` sees it):
    every successful lookup named from the process's root or current
    directory opens one of BGF2's roots.
*/
TraceResult traceChecks(string root)
{
    import std.file : exists, readText, remove, tempDir, thisExePath;
    import std.process : execute, thisProcessID;

    TraceResult r;
    const traceFile = buildPath(tempDir, text("plan-graph-trace-", thisProcessID));
    const readsFile = traceFile ~ ".reads";
    scope (exit)
    {
        if (exists(traceFile))
            remove(traceFile);
        if (exists(readsFile))
            remove(readsFile);
    }
    auto run = execute(["strace", "-f", "-y", "-qq", "-e", "trace=%file", "-o", traceFile, thisExePath,
        "--trace-target=" ~ readsFile, root]);
    if (run.status != 0 || !exists(readsFile))
    {
        r.readSet = r.roots = "the traced plan failed: " ~ run.output;
        return r;
    }

    // The read set, the roots, and what they cover.
    bool[string] covered;
    string[] listings, roots;
    void cover(string path)
    {
        for (string p = path; p.length > 1; p = dirName(p))
        {
            if (p in covered)
                break;
            covered[p] = true;
        }
    }
    foreach (line; readText(readsFile).split('\n'))
    {
        const f = line.split('\t');
        if (f.length < 2)
            continue;
        if (f[0] == "root")
        {
            roots ~= f[1];
            cover(f[1]);
            continue;
        }
        if (f.length < 4 || !f[2].startsWith("/"))
            continue; // an environment variable or a query
        const path = buildNormalizedPath(f[2]);
        cover(path);
        if (f[0] == "listing")
            listings ~= path;
        if (f[0] == "link")
            cover(buildNormalizedPath(dirName(path), f[3]));
    }

    auto events = parseTrace(readText(traceFile), root);
    if (events.length == 0)
    {
        r.readSet = r.roots = "the trace holds no file operation";
        return r;
    }
    const mainPid = events[0].pid;
    bool[int] children; // processes the planner started: `pkg-config`
    foreach (ref e; events)
        if (e.call == "execve" && e.pid != mainPid)
            children[e.pid] = true;

    bool inside;
    size_t looked, fromRoot, childEvents;
    string[] outside, unrooted;
    foreach (ref e; events)
    {
        if (e.path == "/.plan-graph-begin")
        {
            inside = true;
            continue;
        }
        if (e.path == "/.plan-graph-end")
            break;
        if (!inside)
            continue;
        if (e.pid in children)
        {
            ++childEvents;
            continue;
        }
        if (e.path.length == 0)
            continue;
        ++looked;
        const isCovered = e.path in covered || listings.canFind!(l => e.path.startsWith(l ~ "/"));
        if (!isCovered && outside.length < 8)
            outside ~= text(e.call, " ", e.path, e.ok ? "" : " (absent)");
        if (e.pid == mainPid && e.fromRoot)
        {
            ++fromRoot;
            const opensRoot = e.ok && e.call.startsWith("open") && roots.canFind(e.path);
            if (e.ok && !opensRoot && unrooted.length < 8)
                unrooted ~= text(e.call, " ", e.path);
        }
    }
    if (!inside)
        r.readSet = r.roots = "the trace shows no planning";
    if (outside.length)
        r.readSet = "not in the read set:" ~ outside.map!(o => " " ~ o).join(";");
    r.summary = text(looked, " lookups, each in the read set; ", childEvents,
        " in the pkg-config processes, recorded as queries");
    if (unrooted.length)
        r.roots = "named from the root, and not one of BGF2's roots:" ~ unrooted.map!(o => " " ~ o).join(";");
    r.rootsSummary = text(fromRoot, " lookups from the root, each opening one of the ", roots.length, " roots");
    return r;
}

struct EditResult
{
    string failure, summary;
}

/*
Oracle 20 step 2: edits a sample of tracked files that planning did not
read, one at a time, and plans again; the plan must not change. Each edit
appends what would change the plan if planning read the file: a recipe gains
a version, a D module a test-only variable the layout lint rejects, any
other file a line. The file's bytes and modification time are restored.
As a check of the check, the same edit to a recipe planning read must
change the plan.
*/
EditResult editSample(string root, ref const Planned p)
{
    import std.file : exists, getSize, getTimes, isFile, isSymlink, read, setTimes, write;
    import sparkles.build_primitives.git_env : runGit;

    const listed = runGit(["ls-files", "-z"], root);
    if (listed.status != 0)
        return EditResult("git ls-files failed: " ~ listed.output);
    bool[string] wasRead;
    foreach (e; p.reads.entries)
        if (e.kind == ReadKind.file)
            wasRead[e.path] = true;

    string[] dFiles, recipes, others;
    foreach (rel; listed.output.split('\0'))
    {
        if (rel.length == 0)
            continue;
        const path = buildPath(root, rel);
        if (path in wasRead || !exists(path) || isSymlink(path) || !isFile(path) || getSize(path) > 1 << 20)
            continue;
        if (rel.endsWith(".d"))
            dFiles ~= rel;
        else if (rel.endsWith("dub.sdl"))
            recipes ~= rel;
        else
            others ~= rel;
    }
    // A spread of each kind: every k-th of the sorted list.
    string[] pick(string[] from, size_t n)
    {
        from.sort;
        string[] chosen;
        if (from.length == 0)
            return chosen;
        const step = from.length > n ? from.length / n : 1;
        for (size_t i = 0; i < from.length && chosen.length < n; i += step)
            chosen ~= from[i];
        return chosen;
    }
    const ds = pick(dFiles, 10), rs = pick(recipes, 4), os = pick(others, 6);
    const sample = ds ~ rs ~ os;

    string edit(string rel)
    {
        if (rel.endsWith(".d"))
            return "\nversion (unittest) int editSampleVariable;\n";
        if (rel.endsWith("dub.sdl"))
            return "\nversions \"EditSample\"\n";
        return "\n";
    }
    // Plans with `rel` edited; true when the plan differs.
    bool changes(string rel, out string error)
    {
        import std.datetime.systime : SysTime;

        const path = buildPath(root, rel);
        const original = read(path);
        SysTime accessed, modified;
        getTimes(path, accessed, modified);
        scope (exit)
        {
            write(path, original);
            setTimes(path, accessed, modified);
        }
        write(path, cast(const(char)[]) original ~ edit(rel));
        const again = planRepository(root);
        error = again.error;
        return again.error.length || again.text != p.text;
    }

    string changed;
    foreach (rel; sample)
    {
        string error;
        if (changes(rel, error))
            changed ~= " " ~ rel ~ (error.length ? " (" ~ error ~ ")" : "") ~ ";";
    }
    // The check of the check: a test root's recipe planning read.
    string control;
    foreach (e; p.reads.entries)
        if (e.kind == ReadKind.file && e.path.endsWith("/libs/versions/dub.sdl"))
            control = e.path[root.length + 1 .. $];
    string controlError;
    if (control.length == 0 || !changes(control, controlError))
        return EditResult("the same edit to a recipe planning read did not change the plan: " ~ control);
    if (changed.length)
        return EditResult("edits outside the read set changed the plan:" ~ changed);
    return EditResult(null, text(sample.length, " files edited (", ds.length, " D modules, ", rs.length,
        " recipes, ", os.length, " others), none changed the plan; the same edit to ", control, " did"));
}

// CIC5: every read outside a package directory is a workspace input; a
// link's target is read too.
string checkCic5(string root, ref const Planned p, string without = null)
{
    import repository_inputs : repositoryFocus;
    import sparkles.build_primitives.workspace.select : claimLinks, workspaceInputSets;

    auto tree = systemTree();
    const sources = environment.get("SPARKLES_DUB_SOURCES");
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")], tree);
    auto registry = nixRegistrySources(locked.value, sources, tree);
    const workspace = readWorkspaceAt(root).value;
    const graph = buildPackageGraph(workspace.rootName, workspace.recipes, RecipeRole.test, host).value;
    auto options = repositoryFocus(platform, registry.value);
    // The check of the check: one invalidator left out.
    options.workspace.read = options.workspace.read.filter!(r => r != without).array;
    auto inputs = workspaceInputSets(root, tree, graph, workspace, options, host);
    // A link a package holds claims its target for that package (BGW11).
    claimLinks(root, inputs);

    string failures;
    void checkPath(string path)
    {
        while (path.length > 1 && path[$ - 1] == '/')
            path = path[0 .. $ - 1];
        if (!path.startsWith(root ~ "/"))
            return; // the registry's store paths: immutable, keyed by the lockfiles
        if (p.packageDirectories.canFind!(d => path.startsWith(d ~ "/") || path == d))
            return;
        const rel = path[root.length + 1 .. $];
        if (inputs.linkClaims.canFind!(c => c.holds(rel)))
            return;
        if (!inputs.inWorkspace(rel))
            failures ~= " " ~ rel;
    }
    foreach (e; p.reads.entries)
    {
        if (e.kind == ReadKind.environment || e.kind == ReadKind.query)
            continue;
        checkPath(e.path);
        if (e.kind == ReadKind.link)
            checkPath(buildNormalizedPath(dirName(e.path), e.names));
    }
    return failures.length ? "not workspace inputs:" ~ failures : null;
}

// Oracle 24 step 1: outside `unittest` blocks, no planning module imports
// `std.file` or names `std.stdio`'s `File`, and every `ambientAuthority()`
// is in `resolve/tree.d` or `build_graph/execute.d`, which open BGF2's roots.
string sourceAudit(string root)
{
    import sparkles.d_source.mentions : scanSource;
    import sparkles.d_source.tokens : TokenKind;

    string failures;
    foreach (dir; [["build-graph", "build_graph", ""], ["build-primitives", "build_primitives", "resolve"]])
        foreach (e; dirEntries(root.buildPath("libs", dir[0], "src", "sparkles", dir[1], dir[2]),
                "*.d", SpanMode.depth))
        {
            const s = scanSource(readText(e.name));
            const ts = s.tokens;
            const shown = e.name[root.length + 1 .. $];
            bool inTest(size_t i)
            {
                foreach (b; s.unittestBlocks)
                    if (i >= b[0] && i < b[1])
                        return true;
                return false;
            }
            foreach (i, t; ts)
            {
                if (inTest(i) || t.kind != TokenKind.identifier)
                    continue;
                const importsFile = t == "import" && i + 3 < ts.length && ts[i + 1] == "std" && ts[i + 2] == "."
                    && ts[i + 3] == "file";
                const namesFile = t == "stdio" && i + 2 < ts.length && (ts[i + 1] == ":" || ts[i + 1] == ".")
                    && ts[i + 2] == "File";
                const ambient = t == "ambientAuthority" && i + 1 < ts.length && ts[i + 1] == "("
                    && !shown.endsWith("resolve/tree.d") && !shown.endsWith("build_graph/execute.d");
                if (importsFile || namesFile || ambient)
                    failures ~= text(" ", shown, ":", t.line);
            }
        }
    return failures.length ? "reaches the file system directly:" ~ failures : null;
}

// Writes `files` (relative path to text) and `links` (relative path to
// target) beneath a new directory, and returns it.
string diskFixture(string name, string[string] files, string[string] links)
{
    import std.file : mkdirRecurse, symlink, tempDir, write;
    import std.process : thisProcessID;

    const disk = buildPath(tempDir, text("plan-graph-", name, "-", thisProcessID));
    foreach (path, content; files)
    {
        mkdirRecurse(buildPath(disk, path).dirName);
        write(buildPath(disk, path), content);
    }
    foreach (path, target; links)
    {
        mkdirRecurse(buildPath(disk, path).dirName);
        symlink(target, buildPath(disk, path));
    }
    return disk;
}

// Oracle 24 step 3, for the memory and blocking backends: a fixture planned
// in memory and written to disk plans to the same graph and reads.
string backendsAgree()
{
    import std.file : rmdirRecurse;

    string[string] files = [
        "dub.sdl": "name \"r\"\nsubPackage \"t1\"\nsubPackage \"leaf\"\n",
        "t1/dub.sdl": `name "t1"
dependency "r:leaf" path=".."
configuration "library" {
}
configuration "unittest" {
    versions "T1Only"
}
`,
        "t1/source/t1.d": "module t1;\n",
        "leaf/dub.sdl": "name \"leaf\"\n",
        "leaf/source/leaf.d": "module leaf;\nversion (T1Only) int x;\n",
    ];
    const disk = diskFixture("backends", files, null);
    scope (exit)
        rmdirRecurse(disk);
    string[string] inMemory;
    foreach (path, content; files)
        inMemory["/r/" ~ path] = content;
    string planOn(ResolveTree tree, string at)
    {
        ReadSet reads;
        string out_;
        reads = tree.recorded(() @safe {
            auto r = resolve(ResolveRequest(directory: at, subPackage: ":t1", buildType: "unittest",
                platform: platform, testRoot: true), tree);
            if (r.hasError)
            {
                out_ = r.error.message;
                return;
            }
            auto plan = planVariants([r.value], PlanOptions(ToolchainIdentity("ldc", "fixture")), tree);
            auto g = planActions(plan.value, [r.value], at);
            out_ = render(g.value, at);
        });
        foreach (e; reads.entries)
            out_ ~= text("read ", e.kind, " ", e.path[at.length .. $], " ", e.found, "\n");
        return out_;
    }
    const a = planOn(memoryTree(inMemory), "/r");
    const b = planOn(rootedTree([disk]), disk);
    return a == b ? null : "the plans differ:\n" ~ a ~ "---\n" ~ b;
}

/*
Oracle 24 step 4: in a fixture worktree on disk, a relative link to a source
inside it resolves, and the read set lists the link and its target;
retargeting it changes the read set. An absolute link, and a relative one
that climbs out of the worktree, each fail planning naming the link.
*/
string linkScenarios()
{
    import std.file : rmdirRecurse;

    string[string] files = [
        "dub.sdl": "name \"r\"\nsubPackage \"t1\"\nsubPackage \"leaf\"\n",
        "t1/dub.sdl": `name "t1"
dependency "r:leaf" path=".."
configuration "library" {
}
configuration "unittest" {
}
`,
        "t1/source/t1.d": "module t1;\n",
        "leaf/dub.sdl": "name \"leaf\"\n",
        "shared/one.d": "module leaf;\n",
        "shared/two.d": "module leaf;\nint two;\n",
    ];
    string failures;
    ReadSet planWith(string target, out string error)
    {
        const disk = diskFixture("links", files, ["leaf/source/leaf.d": target]);
        scope (exit)
            rmdirRecurse(disk);
        auto tree = rootedTree([disk]);
        auto r = resolve(ResolveRequest(directory: disk, subPackage: ":t1", buildType: "unittest",
            platform: platform, testRoot: true), tree);
        if (r.hasError)
            error = r.error.message.replace(disk, "<root>");
        else
        {
            const plan = planVariants([r.value], PlanOptions(ToolchainIdentity("ldc", "fixture"), layoutLint()),
                tree);
            error = plan.hasError ? text(plan.error).replace(disk, "<root>") : null;
        }
        ReadSet reads;
        foreach (e; tree.reads.entries)
        {
            auto copy = e;
            copy.path = e.path.replace(disk, "<root>");
            reads.put(copy);
        }
        return reads;
    }

    string error;
    const one = planWith("../../shared/one.d", error);
    if (error.length)
        failures ~= " an in-tree link failed planning: " ~ error ~ ";";
    if (!one.entries.canFind!(e => e.kind == ReadKind.link && e.path == "<root>/leaf/source/leaf.d"
            && e.names == "../../shared/one.d"))
        failures ~= " the read set does not list the link;";
    if (!one.entries.canFind!(e => e.kind == ReadKind.file && e.path == "<root>/shared/one.d" && e.found))
        failures ~= " the read set does not list the target;";
    const two = planWith("../../shared/two.d", error);
    if (two.entries == one.entries)
        failures ~= " retargeting the link left the read set as it was;";
    foreach (bad; ["/etc/hostname", "../../../outside.d"])
    {
        cast(void) planWith(bad, error);
        if (!error.canFind("<root>/leaf/source/leaf.d"))
            failures ~= text(" a link to `", bad, "` did not fail planning naming it (", error, ");");
    }
    return failures;
}
