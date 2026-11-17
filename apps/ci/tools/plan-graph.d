#!/usr/bin/env dub
/+ dub.sdl:
    name "plan_graph"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:build-graph" path="../../.."
    dependency "sparkles:unittest-layout" path="../../.."
    dependency "sparkles:d-source" path="../../.."
    // ci's statement of the workspace inputs, for the CIC5 check.
    // (single-file packages take no sourceFiles: `-i=` compiles the import)
    dflags "-I=$PACKAGE_DIR/../src" "-i=repository_inputs" platform="ldc"

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

Needs the dev shell's `SPARKLES_DUB_SOURCES` for the registry packages, and
`strace` (the dev shell's, on Linux) for the trace steps. `--trace-target=F`
is the traced planner: it plans once between two marker lookups and writes
its read set to `F`.
*/
module plan_graph;

import std.algorithm : canFind, endsWith, filter, map, sort, startsWith;
import std.array : array, join, replace, split;
import std.conv : octal, text, to;
import std.file : dirEntries, readText, SpanMode;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.process : environment;
import std.string : indexOf;
import std.stdio : stderr, writeln;
import std.sumtype : match;

import sparkles.build_graph.actions : ActionGraph, ActionKind, CoverageAttempt, Tools, planActions,
    taskNodes;
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

enum host = ["linux", "posix"];

BuildPlatform platform() @safe => BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2113, "1.43.0");

int main(string[] args)
{
    const check = args.canFind("--check");
    const showReads = args.canFind("--reads");
    const traceTarget = args.filter!(a => a.startsWith("--trace-target=")).array;
    const positional = args[1 .. $].filter!(a => !a.startsWith("--")).array;
    const root = buildNormalizedPath(absolutePath(positional.length ? positional[0] : "."));

    if (traceTarget.length)
        return tracedPlan(root, traceTarget[0]["--trace-target=".length .. $]);
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
        return runPackage(root, runOnly[0]["--run=".length .. $], runDir, cache);
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

struct Planned
{
    string error;
    VariantPlan plan;
    ActionGraph graph;
    ReadSet reads;
    string text;
    size_t requests, targets;
    string[] packageDirectories;
    string[] roots;
}

LayoutCheck layoutLint() @safe
{
    return (string path, const(char)[] source, scope bool delegate(const(char)[]) @safe dependedOn,
        scope bool delegate(const(char)[]) @safe versionSet, scope void delegate(uint, string) @safe finding) @safe {
        const r = checkLayout(path, source, dependedOn, versionSet);
        foreach (v; r.violations)
            finding(v.line, v.what);
        return r.parsed;
    };
}

// What the driver takes from the environment, read before planning starts,
// so the trace sees no lookup of `PATH`'s directories inside it.
struct DriverEnvironment
{
    string sources;    // SPARKLES_DUB_SOURCES
    string pkgConfig;  // the `pkg-config` executable, by absolute path
    string[string] pkgConfigVariables;
}

DriverEnvironment driverEnvironment()
{
    import std.file : exists, isFile;

    DriverEnvironment d;
    d.sources = environment.get("SPARKLES_DUB_SOURCES");
    foreach (v; RecordingPkgConfig.variables)
        if (auto value = environment.get(v))
            d.pkgConfigVariables[v] = value;
    const named = environment.get("PKG_CONFIG", "pkg-config");
    d.pkgConfig = named;
    if (!named.canFind('/'))
        foreach (dir; environment.get("PATH", "").split(':'))
            if (dir.length && exists(buildPath(dir, named)) && isFile(buildPath(dir, named)))
            {
                d.pkgConfig = buildPath(dir, named);
                break;
            }
    return d;
}

// A failing lookup the trace shows, marking where planning starts and ends.
void marker(string name) @trusted
{
    import core.sys.posix.unistd : F_OK, access;
    import std.string : toStringz;

    cast(void) access(("/.plan-graph-" ~ name).toStringz, F_OK);
}

Planned planRepository(string root, bool markers = false, string only = null, Tools tools = Tools.init,
    string toolchain = "dev-shell")
{
    const d = driverEnvironment();
    if (d.sources is null)
        return Planned("SPARKLES_DUB_SOURCES is not set; run in the dev shell");
    if (markers)
        marker("begin");
    scope (exit)
        if (markers)
            marker("end");

    Planned p;
    p.roots = [root, d.sources];
    auto tree = rootedTree(p.roots);
    tree.noteEnvironment("SPARKLES_DUB_SOURCES", d.sources, true);
    string fault()
    {
        const fs = tree.faults;
        return fs.length ? text(fs[0].reason, ": ", fs[0].path, fs[0].target.length ? " -> " ~ fs[0].target : "") : null;
    }

    const read = tree.workspace(root);
    if (read.hasError)
        return Planned(text(read.error));
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")], tree);
    if (locked.hasError)
        return Planned(locked.error);
    const registry = nixRegistrySources(locked.value, d.sources, tree);
    if (registry.hasError)
        return Planned(registry.error);
    const graph = buildPackageGraph(read.value.rootName, read.value.recipes, RecipeRole.test, host);
    if (graph.hasError)
        return Planned(text(graph.error));

    Resolution[] rs;
    foreach (ref pkg; graph.value.packages)
    {
        if (only.length && pkg.shortName != only)
            continue;
        auto request = ResolveRequest(directory: root, subPackage: pkg.shortName, buildType: "unittest",
            platform: platform, testRoot: true);
        foreach (n, s; registry.value)
            request.registry[n] = s;
        auto r = resolve(request, tree);
        if (r.hasError)
            return Planned(fault() ? fault() : text(pkg.shortName, ": ", r.error.message));
        rs ~= r.value;
    }
    // The variables the resolved values refer to: the requests pass none.
    foreach (ref r; rs)
        foreach (name; r.environmentInputs)
            tree.noteEnvironment(name, null, false);

    auto pkgConfig = new RecordingPkgConfig(answers(d.pkgConfig), tree, d.pkgConfigVariables.dup);
    // A generator's requests (§7): the shader compiler's application and a
    // package's device configuration, by the package's directory.
    PlanExpected!(Resolution, PlanError) resolveTool(string directory, string configuration) @safe
    {
        foreach (ref pkg; graph.value.packages)
            if (root ~ "/" ~ pkg.path == directory)
            {
                auto request = ResolveRequest(directory: root, subPackage: pkg.shortName,
                    configuration: configuration, platform: platform);
                foreach (n, s; registry.value)
                    request.registry[n] = s;
                auto r = resolve(request, tree);
                if (r.hasError)
                    return planErr!Resolution(PlanError(text(pkg.shortName, ": ", r.error.message)));
                return planOk!PlanError(r.value);
            }
        return planErr!Resolution(PlanError("a generator names a directory that holds no package", directory));
    }
    auto options = PlanOptions(ToolchainIdentity("ldc", toolchain), layoutLint(), registry.value.keys, pkgConfig);
    options.resolveTool = &resolveTool;
    options.root = root;
    auto planned = planVariants(rs, options, tree);
    if (planned.hasError)
        return Planned(text(planned.error));
    p.plan = planned.value;
    p.reads = tree.reads;
    p.requests = rs.length;
    foreach (ref r; rs)
        p.targets += r.targets.length;
    foreach (ref r; rs)
        foreach (ref t; r.targets)
            if (!p.packageDirectories.canFind(t.directory))
                p.packageDirectories ~= t.directory;

    auto g = planActions(p.plan, rs, root, tools);
    if (g.hasError)
        return Planned(text(g.error));
    p.graph = g.value;
    p.text = render(p.graph, root);
    return p;
}

// One process's `pkg-config` answers, which no worktree file decides: the
// gate plans many times, and each plan still records every query it makes.
PkgConfigDriver answers(string executable)
{
    static PkgConfigDriver memo;
    if (memo is null)
        memo = new MemoPkgConfig(new SystemPkgConfig(executable));
    return memo;
}

final class MemoPkgConfig : PkgConfigDriver
{
    private PkgConfigDriver inner;
    private bool[string] exists_;
    private string[string] libs_, cflags_, pc_;
    private bool[string] libsOk, cflagsOk;

    this(PkgConfigDriver inner) @safe { this.inner = inner; }

    bool exists(string name) @safe
    {
        if (auto e = name in exists_)
            return *e;
        return exists_[name] = inner.exists(name);
    }

    bool libs(const string[] names, out string output) @safe
    {
        const key = names.join(" ");
        if (key !in libsOk)
        {
            string o;
            libsOk[key] = inner.libs(names, o);
            libs_[key] = o;
        }
        output = libs_[key];
        return libsOk[key];
    }

    bool cflags(const string[] names, out string output) @safe
    {
        const key = names.join(" ");
        if (key !in cflagsOk)
        {
            string o;
            cflagsOk[key] = inner.cflags(names, o);
            cflags_[key] = o;
        }
        output = cflags_[key];
        return cflagsOk[key];
    }

    string pcFile(string name) @safe
    {
        if (auto p = name in pc_)
            return *p;
        return pc_[name] = inner.pcFile(name);
    }
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

// The graph as text: actions sorted by id, then edges.
string render(ref const ActionGraph g, string root) @safe
{
    string[] blocks;
    foreach (ref a; g.actions)
    {
        string b = text(a.id.text, "  weight=", a.weight, a.provisional ? "  provisional" : "", "\n");
        b ~= a.action.match!(
            (ref const ProcessAction p) => text("  run ", p.argv.join(" "), p.cwd.length ? "  (in " ~ p.cwd ~ ")" : "", "\n"),
            (ref const InProcessAction i) => text("  in-process ", i.handler, " ", i.arguments.length, " arguments\n"),
            (ref const InertAction x) => text("  inert ", x.note, "\n"));
        foreach (o; a.outputs)
            b ~= text("  out $OUT/", o.path, o.tree ? "/**" : "", "\n");
        blocks ~= b;
    }
    blocks.sort;
    string[] edges = g.edges.map!(e => text(e.prerequisite.text, " -", e.condition, "-> ", e.dependent.text)).array;
    edges.sort;
    return blocks.join("") ~ "edges\n" ~ edges.map!(e => "  " ~ e ~ "\n").join("");
}

// Oracle 14, invariant 7, on a package of the repository: its coverage
// attempt and plain fallback, and its plain test alone. The plain compile
// behind the `onFailure` edge must be the plain test's: one id, one argument
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

// One file operation of a system-call trace.
struct TraceEvent
{
    int pid;
    string call;
    string path;    // absolute; empty for an operation on a held descriptor itself
    bool fromRoot;  // named from the process's root or current directory
    bool ok;
}

// Parses `strace -f -y -e trace=%file` output, joining resumed calls.
TraceEvent[] parseTrace(string trace, string cwd)
{
    import std.string : indexOf, lastIndexOf, strip;

    TraceEvent[] events;
    string[int] unfinished;
    foreach (raw; trace.split('\n'))
    {
        string line = raw.strip;
        if (line.length == 0)
            continue;
        const space = line.indexOf(' ');
        if (space < 0)
            continue;
        int pid;
        try
            pid = line[0 .. space].to!int;
        catch (Exception)
            continue;
        string body_ = line[space + 1 .. $].strip;
        if (body_.endsWith("<unfinished ...>"))
        {
            unfinished[pid] = body_[0 .. $ - "<unfinished ...>".length];
            continue;
        }
        if (body_.startsWith("<..."))
        {
            const resumed = body_.indexOf("resumed>");
            if (resumed < 0 || pid !in unfinished)
                continue;
            body_ = unfinished[pid] ~ body_[resumed + "resumed>".length .. $];
            unfinished.remove(pid);
        }
        if (body_.startsWith("+++") || body_.startsWith("---"))
            continue;
        const open = body_.indexOf('(');
        const eq = body_.lastIndexOf(") = ");
        if (open < 0 || eq < 0)
            continue;
        TraceEvent e;
        e.pid = pid;
        e.call = body_[0 .. open];
        const args = body_[open + 1 .. eq];
        const ret = body_[eq + 4 .. $];
        e.ok = !ret.startsWith("-1");
        string base, name;
        size_t i;
        if (args.startsWith("AT_FDCWD"))
        {
            e.fromRoot = true;
            base = cwd;
            i = "AT_FDCWD".length;
            while (i < args.length && args[i] != '"')
                ++i;
            name = quoted(args, i);
        }
        else if (args.startsWith("\""))
        {
            e.fromRoot = true;
            base = cwd;
            name = quoted(args, i);
        }
        else
        {
            const lt = args.indexOf('<');
            const gt = args.indexOf(">,");
            if (lt < 0 || gt < 0)
                continue; // a descriptor without a path: not a lookup
            base = args[lt + 1 .. gt];
            i = gt;
            while (i < args.length && args[i] != '"')
                ++i;
            name = i < args.length ? quoted(args, i) : null;
        }
        if (name.length == 0)
            e.path = null; // the descriptor itself (AT_EMPTY_PATH)
        else
            e.path = name.startsWith("/") ? buildNormalizedPath(name) : buildNormalizedPath(base, name);
        events ~= e;
    }
    return events;
}

// The C string literal at `args[i]`, which is `"`; advances past it.
string quoted(string args, ref size_t i)
{
    string s;
    ++i;
    for (; i < args.length && args[i] != '"'; ++i)
    {
        if (args[i] == '\\' && i + 1 < args.length)
        {
            ++i;
            s ~= args[i] == 'n' ? '\n' : args[i];
        }
        else
            s ~= args[i];
    }
    ++i;
    return s;
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

// The executable `name` on `PATH`, by absolute path, its links resolved.
string onPath(string name)
{
    import std.file : exists, isFile, readLink, isSymlink;
    import std.path : absolutePath;

    foreach (dir; environment.get("PATH", "").split(':'))
    {
        const p = buildPath(dir, name);
        if (dir.length && exists(p) && isFile(p))
            return p;
    }
    return null;
}

/*
E3's local execution, by hand: plans the test root of the package `only`
(`:versions`), with the toolchain from `PATH` by absolute path, and runs its
actions into `into` on the task-DAG executor: compiles, archives and the
link with the fixed environment, then the test. Prints each task's lines
and its outcome; the exit status is the run's.
*/
int runPackage(string root, string only, string into, string cache)
{
    import std.file : mkdirRecurse;
    import std.parallelism : totalCPUs;
    import std.stdio : stdout;
    import sparkles.build_graph.execute : RunLayout, executionNodes, runActions;
    import sparkles.build_primitives.task.action : EnvEntry;

    auto tools = Tools(compiler: onPath("ldc2"), archiver: onPath("ar"), cc: onPath("cc"), linker: onPath("ld.lld"),
        fail: onPath("false"), deviceCompiler: onPath("ldc2-vulkan"));
    foreach (name; ["spirv-val", "spirv-opt", "spirv-dis", "spirv-as", "spirv-cross", "glslangValidator"])
        tools.shaderTools ~= [name, onPath(name)];
    // The fork's dependency output, which a compile's manifest comes from.
    if (tools.compiler !is null)
    {
        import std.process : execute;

        const help = execute([tools.compiler, "--help-hidden"]);
        tools.dependencyOutput = help.output.canFind("makedeps-digests");
    }
    if (tools.compiler is null || tools.archiver is null || tools.cc is null || tools.linker is null)
    {
        stderr.writeln("plan-graph: ldc2, ar, cc and ld.lld must be on PATH");
        return 2;
    }
    // §8: the identity every key covers, the configuration passed, the
    // compiler's own tree remapped (BGA11).
    const toolchain = toolchainOf(tools);
    tools.config = toolchain.config;
    if (toolchain.root.length)
        tools.prefixMaps = [toolchain.root ~ "=/ldc"];
    auto p = planRepository(root, false, only, tools, toolchain.identity);
    if (p.error.length)
    {
        stderr.writeln("plan-graph: ", p.error);
        return 1;
    }
    if (p.requests == 0)
    {
        stderr.writeln("plan-graph: no package ", only);
        return 2;
    }
    mkdirRecurse(into);
    // Generators and tests run with the environment they are given here,
    // declared whole (BGX1): the driver's own.
    // Oracle 11 step 1 (BGX1): a `dub` first on their `PATH` that records
    // each call and fails, so a test that runs dub is seen.
    import std.file : exists, readText, setAttributes, write;

    const trap = buildPath(into, "dub-trap");
    mkdirRecurse(trap);
    write(buildPath(trap, "dub"), "#!/bin/sh\necho \"$@\" >> '" ~ buildPath(trap, "calls") ~ "'\nexit 1\n");
    setAttributes(buildPath(trap, "dub"), octal!755);
    EnvEntry[] declared;
    foreach (name, value; environment.toAA)
        declared ~= EnvEntry(name, name == "PATH" ? trap ~ ":" ~ value : value);
    declared.sort!((a, b) => a.name < b.name);
    const layout = RunLayout(root, into, cache, toolchain.identity);
    auto nodes = executionNodes(p.graph, layout, declared);
    auto w = stdout.lockingTextWriter;
    import sparkles.build_graph.execute : RunStats;

    RunStats stats;
    const r = runActions(nodes, p.graph, layout, w, cast(uint) totalCPUs, &stats);
    writeln(p.graph.actions.length, " actions; exit ", r.exitCode);
    if (cache.length)
        writeln("store ", cache, ": ", stats.summary);
    // BGS5: eviction after the run, off its publish path.
    if (cache.length)
        cast(void) cacheOp(cache, "evict");
    if (exists(buildPath(trap, "calls")))
    {
        stderr.writeln("plan-graph: BGX1: a test ran dub: ", readText(buildPath(trap, "calls")));
        return 1;
    }
    writeln("BGX1: no test ran dub");
    return r.exitCode;
}

/// The toolchain as a run names it (§8).
struct Toolchain
{
    string identity; /// the digest of every tool's store-path closure (BGT2)
    string config;   /// the compiler's configuration file (BGT1)
    string root;     /// the compiler's own tree, holding druntime's and Phobos' sources
}

/*
§8: the compiler reports its configuration file and where `object` lies,
so the run passes the one explicitly and remaps the other's tree (BGA11);
the identity is the SHA-256 of the sorted store-path closure of every tool
the run names, the test runner included (BGT1, BGT2).
*/
Toolchain toolchainOf(const Tools tools)
{
    import std.digest.sha : sha256Of;
    import std.file : tempDir, write;
    import std.process : execute;
    import std.string : indexOf, lineSplitter, strip;
    import sparkles.build_graph.store : hexOf;

    Toolchain t;
    const probe = buildPath(tempDir, "plan-graph-toolchain-probe.d");
    write(probe, "module probe;\n");
    foreach (line; execute([tools.compiler, "-v", "-o-", probe]).output.lineSplitter)
    {
        if (line.startsWith("config "))
        {
            auto rest = line["config ".length .. $].strip;
            const space = rest.indexOf(' ');
            t.config = (space < 0 ? rest : rest[0 .. space]).idup;
        }
        else if (line.startsWith("import") && line.canFind("object\t("))
        {
            const open = line.indexOf('(');
            const at = line.indexOf("/include/");
            if (open >= 0 && at > open)
                t.root = line[open + 1 .. at].idup;
        }
    }
    string[] paths = [tools.compiler, t.config, tools.cc, tools.linker, tools.archiver, tools.fail,
        tools.deviceCompiler, environment.get("SPARKLES_TEST_RUNNER", "")];
    foreach (tool; tools.shaderTools)
        paths ~= tool[1];
    paths = paths.filter!(p => p.length).array;
    const closure = execute(["nix-store", "--query", "--requisites"] ~ paths);
    // A toolchain outside the store is named by its paths alone (BGT3 is E3's).
    const listing = closure.status == 0 ? closure.output.lineSplitter.map!(l => l.idup).array.sort.release.join("\n")
        : paths.join("\n");
    t.identity = hexOf(sha256Of(listing));
    return t;
}

// Whether a lease holder, `<pid>-<start>`, still runs (BGS4).
bool holderAlive(string holder)
{
    import core.sys.posix.signal : kill;
    import std.conv : ConvException, to;

    const dash = holder.indexOf('-');
    if (dash <= 0)
        return false;
    try
        return kill(holder[0 .. dash].to!int, 0) == 0;
    catch (ConvException)
        return false;
}

/**
BGS7's operations on the store beneath `cache`, the test-only driver's
`ci cache`: `size`, `list`, `gc`, `verify`, `evict[=<results bytes>]`,
and `remove-key=`, `remove-task=`, `remove-package=` or
`remove-toolchain=` a value.
*/
int cacheOp(string cache, string op)
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.build_graph.store : ResultRecord, Store;
    import sparkles.event_horizon.sys : BlockingVfs;
    import std.process : thisProcessID;

    auto vfs = new BlockingVfs;
    auto top = openRoot!(Rights.all)(vfs, cache, ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
    if (top.hasError)
    {
        stderr.writeln("plan-graph: no store at ", cache);
        return 2;
    }
    auto build = top.value.walkAll("build");
    Store!(typeof(build.value)) store;
    if (build.hasError || !Store!(typeof(build.value)).open(build.value, text(thisProcessID, "-0"), store))
    {
        stderr.writeln("plan-graph: cannot open the store at ", cache);
        return 2;
    }
    const value = op.indexOf('=') >= 0 ? op[op.indexOf('=') + 1 .. $] : null;
    const name = op.indexOf('=') >= 0 ? op[0 .. op.indexOf('=')] : op;
    bool alive(string holder) => holderAlive(holder); // a delegate, as the store takes
    switch (name)
    {
        case "size":
            ulong bytes;
            const entries = store.entries;
            foreach (ref e; entries)
                bytes += e.bytes;
            writeln(entries.length, " results, ", bytes, " bytes; records ", store.recordBytes, " bytes");
            return 0;
        case "list":
            foreach (ref e; store.entries)
                writeln(e.key, " ", e.bytes, " ", e.recency, " ", e.task);
            return 0;
        case "gc":
            writeln(store.collectGarbage(&alive), " entries collected");
            return 0;
        case "verify":
            const corrupt = store.verify();
            foreach (k; corrupt)
                writeln("corrupt: ", k);
            writeln(corrupt.length, " corrupt");
            return corrupt.length ? 1 : 0;
        case "evict":
            const bound = value.length ? value.to!ulong : 20UL << 30;
            const r = store.evict(bound, 1UL << 30, &alive);
            writeln(r.evicted.length, " evicted, ", r.leased.length, " held by leases, ", r.recordsDropped,
                " records dropped; ", r.resultBytes, " result bytes, ", r.recordBytes, " record bytes");
            return 0;
        case "remove-key", "remove-task", "remove-package", "remove-toolchain":
            bool which(ref const ResultRecord r)
            {
                const parts = r.task.split(":");
                return name == "remove-key" ? r.resultKey == value
                    : name == "remove-task" ? r.task == value
                    : name == "remove-package" ? parts.length > 1 && parts[1] == value.replace(":", ".")
                    : r.toolchain == value;
            }
            string[] held;
            const removed = store.remove(&which, &alive, held);
            foreach (k; held)
                writeln("held by a live lease: ", k);
            writeln(removed.length, " removed");
            return held.length ? 1 : 0;
        default:
            stderr.writeln("plan-graph: unknown cache operation ", op);
            return 2;
    }
}
