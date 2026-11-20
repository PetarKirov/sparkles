/**
The build graph's driver for this repository (build-graph PLAN, E3): plans
the test selection, or one package's test root, and runs it on the
task-DAG executor against the shared store, with the toolchain from `PATH`
named by absolute path (§8).

`ci` drives it (`ci cache explain`, `ci commits build-each`), and so
does the test-only planner, `apps/ci/tools/plan-graph.d`, whose `--check`
and `--run=` verify E2's and E3's gates through it.

Needs the dev shell's `SPARKLES_DUB_SOURCES` for the registry packages, or
the sources `--fetch-sources` fetched (BGR4).
*/
module graph_driver;


import core.time : Duration, hours, minutes, seconds;
import std.algorithm : any, canFind, endsWith, filter, map, sort, startsWith, uniq;
import std.array : array, join, replace, split;
import std.conv : octal, text, to;
import std.file : dirEntries, readText, SpanMode;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName;
import std.process : environment;
import std.string : indexOf;
import std.stdio : stderr, writeln;
import std.sumtype : match;
import std.typecons : Nullable;

import sparkles.build_graph.actions : ActionGraph, ActionKind, CoverageAttempt, TestLeg, TestProgram, Tools,
    planActions, taskNodes;
import sparkles.build_graph.execute : RunReporting, RunStats;
import sparkles.build_graph.variants : LayoutCheck, PlanError, PlanOptions, Role, ToolchainIdentity,
    VariantPlan, planVariants;
import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;
import sparkles.build_primitives.resolve.configure : Resolution, ResolveRequest, resolve;
import sparkles.build_primitives.resolve.libraries : PkgConfigDriver, RecordingPkgConfig, SystemPkgConfig;
import sparkles.build_primitives.resolve.platform : BuildPlatform;
import sparkles.build_primitives.resolve.registry : nixRegistrySources, readDubLocks;
import sparkles.build_primitives.resolve.tree : ResolveTree, memoryTree, rootedTree, systemTree;
import sparkles.build_primitives.task.action : EnvEntry, InProcessAction, InertAction, ProcessAction, TaskAction;
import sparkles.build_primitives.task.executor : TaskContext;
import sparkles.build_primitives.task.process : InProcessHandler;
import sparkles.event_horizon.sched : Sched;
import sparkles.build_primitives.workspace.discovery : ReadKind, ReadSet, readWorkspaceAt;
import sparkles.build_primitives.workspace.package_graph : RecipeRole, buildPackageGraph;
import sparkles.unittest_layout.lint : checkLayout;

enum host = ["linux", "posix"];

/**
The platform `compiler` builds for: LDC's or DMD's (build-graph D19), with
the frontend and compiler versions its `--version` reports. Memoized per
compiler.
*/
BuildPlatform platformOf(string compiler) @safe
{
    import std.path : baseName;
    import std.process : execute;
    import std.regex : matchFirst, regex;

    static BuildPlatform[string] memo;
    if (auto known = compiler in memo)
        return *known;
    const dmd = compiler.baseName.startsWith("dmd");
    const output = execute([compiler, "--version"]).output;
    // `DMD64 D Compiler v2.112.1`; LDC: `(1.43.0)` and `based on DMD v2.113.0`.
    const frontend = output.matchFirst(regex(`v2\.(\d+)`));
    const own = dmd ? output.matchFirst(regex(`v(\d+\.\d+\.\d+)`)) : output.matchFirst(regex(`\((\d+\.\d+\.\d+)`));
    auto p = BuildPlatform(host.dup, ["x86_64"], dmd ? "dmd" : "ldc", dmd ? "dmd" : "ldc2",
        frontend ? 2000 + frontend[1].to!int : 2113, own ? own[1].idup : (dmd ? "2.112.1" : "1.43.0"));
    memo[compiler] = p;
    return p;
}

/// The processors online, as `std.parallelism.totalCPUs` counts them.
uint logicalProcessors() @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : _SC_NPROCESSORS_ONLN, sysconf;

        const n = sysconf(_SC_NPROCESSORS_ONLN);
        return n > 0 ? cast(uint) n : 1;
    }
    else
    {
        import core.sys.windows.winbase : GetSystemInfo, SYSTEM_INFO;

        SYSTEM_INFO info;
        GetSystemInfo(&info);
        return info.dwNumberOfProcessors ? info.dwNumberOfProcessors : 1;
    }
}

/// The platform of the compiler `$DC` names, LDC's by default.
BuildPlatform platform() @safe => platformOf(compilerName);

/// The compiler a run builds with: `$DC` (`ldc2` or `dmd`), LDC by default.
string compilerName() @safe
{
    import std.path : baseName;

    const dc = environment.get("DC", "ldc2");
    return dc.baseName.startsWith("dmd") ? "dmd" : "ldc2";
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
    /// D62: per package, the tools its tests declare they run (only `dub`).
    string[][string] testTools;
    /// Each planned single-file package's link task, by its file (CIC8).
    string[string] singleFileLinks;
    /// Why each single-file package that could not be resolved was left out:
    /// its own failure, not the run's (§5.5).
    string[string] singleFileErrors;
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
    d.sources = fetchedSources.length ? fetchedSources : environment.get("SPARKLES_DUB_SOURCES");
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
    string toolchain = "dev-shell", bool lint = true, const string[] packages = null, bool coverage = false,
    const string[] singleFiles = null, const string[] applications = null)
{
    // The platform the tools' compiler builds for (D19).
    auto platform = platformOf(tools.compiler);
    // The packages planned: `only`, else `packages`, else every one, unless
    // only single-file packages are asked for.
    bool chosen(string name) => only.length ? name == only : packages.length ? packages.canFind(name)
        : !singleFiles.length && !applications.length;

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
    size_t[][] testRequests; // per chosen package, its test requests' indices
    CoverageAttempt[] attempts;
    foreach (ref pkg; graph.value.packages)
    {
        if (!chosen(pkg.shortName))
            continue;
        // CIC7: with coverage, a `-cov` test whose plain one is its fallback.
        size_t[] mine;
        foreach (buildType; coverage ? ["unittest-cov", "unittest"] : ["unittest"])
        {
            auto request = ResolveRequest(directory: root, subPackage: pkg.shortName, buildType: buildType,
                platform: platform, testRoot: true);
            foreach (n, s; registry.value)
                request.registry[n] = s;
            auto r = resolve(request, tree);
            if (r.hasError)
                return Planned(fault() ? fault() : text(pkg.shortName, ": ", r.error.message));
            mine ~= rs.length;
            rs ~= r.value;
        }
        if (coverage)
            attempts ~= CoverageAttempt(mine[0], mine[1]);
        testRequests ~= mine;
    }
    // `ci commits build-each` (M11): packages' default configurations as
    // applications, built with dub's `debug` build type, as `dub build` does.
    foreach (name; applications)
    {
        auto request = ResolveRequest(directory: root, subPackage: name, buildType: "debug", platform: platform);
        foreach (n, s; registry.value)
            request.registry[n] = s;
        auto r = resolve(request, tree);
        if (r.hasError)
            return Planned(fault() ? fault() : text(name, ": ", r.error.message));
        rs ~= r.value;
    }
    // CIC8: single-file packages (examples), as applications built with
    // dub's `debug` build type, their in-tree dependencies the worktree's.
    foreach (file; singleFiles)
    {
        auto request = ResolveRequest(singleFile: file, buildType: "debug", platform: platform,
            inTree: [read.value.rootName: root]);
        foreach (n, s; registry.value)
            request.registry[n] = s;
        auto r = resolve(request, tree);
        if (r.hasError)
        {
            p.singleFileErrors[file] = fault() ? fault() : r.error.message;
            continue;
        }
        rs ~= r.value;
    }
    // D61: the programs each test runs, declared beside its package's recipe,
    // planned as requests of their own whose tests do not run.
    TestProgram[] programs;
    string[][string] testTools;
    {
        import std.json : JSONException, JSONType, parseJSON;

        string[] testDirectories, testPackages;
        foreach (ref pkg; graph.value.packages)
            if (chosen(pkg.shortName))
            {
                testDirectories ~= pkg.path.length ? root ~ "/" ~ pkg.path : root;
                testPackages ~= pkg.shortName;
            }
        foreach (ti, dir; testDirectories)
        {
            const file = dir ~ "/test-programs.json";
            string json;
            if (!tree.readText(file, json))
                continue;
            try
            {
                // D62: a test whose subject is dub declares it, with its reason.
                if (auto declaredTools = "tools" in parseJSON(json))
                    foreach (entry; declaredTools.array)
                    {
                        if (entry["name"].str != "dub" || !("reason" in entry) || !entry["reason"].str.length)
                            return Planned(text(file, ": a test may declare only `dub`, with a reason (D62)"));
                        testTools[testPackages[ti]] ~= "dub";
                    }
                const parsed = parseJSON(json);
                foreach (entry; "programs" in parsed ? parsed["programs"].array : null)
                {
                    const at = buildNormalizedPath(dir, entry["directory"].str);
                    string sub;
                    foreach (ref pkg; graph.value.packages)
                        if ((pkg.path.length ? root ~ "/" ~ pkg.path : root) == at)
                            sub = pkg.shortName;
                    auto request = ResolveRequest(directory: sub.length ? root : at, subPackage: sub,
                        configuration: entry["configuration"].str, buildType: entry["buildType"].str,
                        platform: platform,
                        testRoot: "testRoot" in entry && entry["testRoot"].type == JSONType.true_);
                    foreach (n, s; registry.value)
                        request.registry[n] = s;
                    auto r = resolve(request, tree);
                    if (r.hasError)
                        return Planned(fault() ? fault() : text(file, ": ", r.error.message));
                    rs ~= r.value;
                    foreach (test; testRequests[ti])
                        programs ~= TestProgram(test: test, program: rs.length - 1, variable: entry["variable"].str);
                }
            }
            catch (JSONException e)
                return Planned(text(file, ": ", e.msg));
        }
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
    // `lint` false only for oracle 8's revert check: without it a test can
    // misread a dependency's aggregate.
    auto options = PlanOptions(ToolchainIdentity(platform.compiler, toolchain), lint ? layoutLint() : null, registry.value.keys,
        pkgConfig);
    options.host = platform;
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

    auto g = planActions(p.plan, rs, root, tools, attempts, programs);
    if (g.hasError)
        return Planned(text(g.error));
    p.graph = g.value;
    foreach (ref a; p.graph.actions)
        if (a.kind == ActionKind.link && a.variant < p.plan.variants.length)
            foreach (file; singleFiles)
                if (p.plan.variants[a.variant].settings.sourceFiles.canFind(file))
                    p.singleFileLinks[file] = a.id.text;
    p.text = render(p.graph, root);
    p.testTools = testTools;
    return p;
}

// One process's `pkg-config` answers, which no worktree file decides: the
// gate plans many times, and each plan still records every query it makes.
__gshared PkgConfigDriver pkgConfigMemo;

PkgConfigDriver answers(string executable)
{
    if (pkgConfigMemo is null)
        pkgConfigMemo = new MemoPkgConfig(new SystemPkgConfig(executable));
    return pkgConfigMemo;
}

/// Forgets the answers: the next plan asks `pkg-config` again (an oracle that
/// changes its search path between plans).
void forgetPkgConfigAnswers() { pkgConfigMemo = null; }

final class MemoPkgConfig : PkgConfigDriver
{
    private PkgConfigDriver inner;
    private bool[string] exists_;
    private string[string] libs_, cflags_, pc_;
    private bool[string] libsOk, cflagsOk;
    private string[] path_;
    private bool searched;
    private string[][string] requires_;

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

    string[] searchPath() @safe
    {
        if (!searched)
        {
            path_ = inner.searchPath();
            searched = true;
        }
        return path_.dup;
    }

    string[] requires(string name) @safe
    {
        if (auto r = name in requires_)
            return (*r).dup;
        return (requires_[name] = inner.requires(name)).dup;
    }
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

// One file operation of a system-call trace.
struct TraceEvent
{
    int pid;
    string call;
    string path;    // absolute; empty for an operation on a held descriptor itself
    bool fromRoot;  // named from the process's root or current directory
    bool ok;
    string args;    // the call's arguments, as strace prints them
    string ret;     // its result: `3`, `-1 ENOENT (No such file or directory)`
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
        e.args = args.idup;
        e.ret = ret.idup;
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
/// Oracle 3: whether a run traces its compiles (`--trace-compiles`).
__gshared bool traceCompiles;
/// `plan-graph --run --runner-core`: tests through the runner core (CIC11).
__gshared bool runnerCore;
/// BGK6 by hand: compiles run as with a compiler without the fork's
/// dependency output (`--no-dependency-output`).
__gshared bool noDependencyOutput;
/// Oracle 3 over an earlier traced run, running nothing (`--oracle3-only`).
__gshared bool oracle3Only;

/// `<n>s`, `<n>m`, `<n>h` or `0` as a duration, or null.
Nullable!Duration parseLimit(string s)
{
    import std.ascii : isDigit;
    import std.algorithm.searching : all;

    if (s == "0")
        return Nullable!Duration(Duration.zero);
    if (s.length < 2 || !s[0 .. $ - 1].all!isDigit)
        return Nullable!Duration.init;
    const n = s[0 .. $ - 1].to!long;
    switch (s[$ - 1])
    {
        case 's': return Nullable!Duration(n.seconds);
        case 'm': return Nullable!Duration(n.minutes);
        case 'h': return Nullable!Duration(n.hours);
        default: return Nullable!Duration.init;
    }
}

@("graph_driver.parseLimit")
@system unittest
{
    assert(parseLimit("90s").get == 90.seconds && parseLimit("2h").get == 2.hours);
    assert(parseLimit("0").get == Duration.zero);
    assert(parseLimit("m").isNull && parseLimit("5d").isNull && parseLimit("-1m").isNull);
}

/// The weight a run admits at once; 0 for one per processor.
__gshared uint runJobs;

/// A test's limit (`--test-timeout=`, BGA12); `Duration.max` keeps the default.
__gshared Duration testTimeout = Duration.max;

/// What a run confines (D39's spike).
enum Confinement
{
    none,   ///
    builds, /// compiles, archives, links and generators
    tests,  /// those and the tests
}

/// What a run asks for, beyond its package.
struct RunOptions
{
    string into;   /// the run directory, absolute; made when missing
    string cache;  /// the cache directory holding the store; empty runs without one
    bool check;    /// BGS9's determinism check
    string[] checkTasks; /// with `check`, the tasks it checks (CIC13's sample); empty for every keyed one
    /// The tasks to run, each an id or a prefix only one id has, with every
    /// action they need; empty runs the whole plan.
    string[] tasks;
    string[] replaceTasks; /// BGS7: tasks whose published result a fresh execution replaces
    Confinement confine;    /// D39's spike
    bool traceCompiles;     /// oracle 3: every compile under `strace`
    uint jobs;              /// the weight admitted at once; 0 for one per processor
    bool echo;              /// the reporter's lines also go to standard output
    bool failFast;          /// cancel the rest at the first failure
    bool noLayoutLint;      /// plan without BGV4's lint (oracle 8's revert check)
    double hashSample = 1.0 / 64; /// BGS6: the fraction of hits a lookup rehashes
    /// Tests run through the runner core, as `test:leg` actions (CIC11),
    /// instead of as their binaries' own processes.
    bool runnerCore;
    /// The packages whose test roots to plan, with `only` null; empty plans
    /// every one.
    string[] packages;
    /// The legs each test binary runs in (CIC11, CIC14); empty keeps the
    /// graph's default.
    TestLeg[] legs;
    /// CIC7: each test a `-cov` attempt, its plain test the fallback.
    bool coverage;
    /// `ci test --build-only`: the test binaries and what they link, and no
    /// test.
    bool buildOnly;
    /// The transcript's form, or a dry run (CIC1).
    RunReporting reporting;
    /// CIC12: the kinds whose actions must reuse a stored result.
    string[] requireCached;
    /// `--sanitize address` (M8): flags every compile and link takes, and the
    /// variables every test and generator runs with.
    string[] extraFlags;
    EnvEntry[] runtimeEnvironment; /// ditto
    /// Runner options a package's legs add, by its name (`sparkles:base`).
    string[][string] testArguments;
    /// Single-file packages to plan as applications (CIC8): examples.
    string[] singleFiles;
    /// Packages to plan in their default configurations, as `dub build`
    /// builds them (`ci commits build-each`).
    string[] applications;
    /// The client's own in-process actions, by name.
    InProcessHandler[string] handlers;
    /// BGS8's explain: every action looked up, nothing executed or written;
    /// `GraphRun.stats.explained` holds the verdicts.
    bool explain;
    /// Changes the tools found on `PATH` before the toolchain is identified
    /// (oracle 9's substitutions).
    void delegate(ref Tools) adjustTools;
    /// Changes the plan before it runs (the oracles' wrapped actions).
    void delegate(ref Planned) adjustPlan;
    /// Changes the process a task runs, after its key is planned: a tool that
    /// behaves otherwise under the same key (oracle 19's nondeterministic
    /// compiler). Called with each process task's id and its concrete action.
    void delegate(string task, ref ProcessAction concrete) adjustExecution;
}

/// What a run of the graph did.
struct GraphRun
{
    string error;        /// why it could not run; null when it ran
    string into;         /// its run directory; a check's is discarded after it (BGS9)
    Planned plan;        ///
    Toolchain toolchain; ///
    int exitCode;        /// the run's
    RunStats stats;      /// what each action did (BGS8, BGK1)
    string log;          /// the reporter's lines
    string dubCalls;     /// what tests passed to `dub` (BGX1); empty when none ran it
}

/**
Plans the test root of the package `only` (every package's when null) with
the tools on `PATH`, named by absolute path, and runs it on the task-DAG
executor into `o.into`, against the store beneath `o.cache` when one is
named.
*/
GraphRun runGraph(string root, string only, RunOptions o)
{
    import std.array : appender;
    import std.file : exists, mkdirRecurse, readText;
    import sparkles.build_graph.execute : RunLayout, executionNodes, runActions;

    GraphRun g;
    Tools tools;
    if (const why = pathTools(tools, g.toolchain))
        return GraphRun(why);
    if (o.adjustTools !is null)
    {
        o.adjustTools(tools);
        g.toolchain = toolchainOf(tools);
        tools.config = g.toolchain.config;
        tools.prefixMaps = g.toolchain.root.length ? [g.toolchain.root ~ "=/ldc"] : null;
    }
    if (o.legs.length)
        tools.testLegs = o.legs;
    tools.extraFlags = o.extraFlags.dup;
    tools.runtimeEnvironment = o.runtimeEnvironment.dup;
    foreach (pkg, more; o.testArguments)
        tools.testArguments[pkg] = more.dup;
    g.plan = planRepository(root, false, only, tools, g.toolchain.identity, !o.noLayoutLint, o.packages,
        o.coverage, o.singleFiles, o.applications);
    if (g.plan.error.length)
        return GraphRun(g.plan.error);
    // Single files that all failed to plan leave nothing to run but are no
    // error of the run's: each is its own (§5.5).
    if (g.plan.requests == 0 && !o.singleFiles.length)
        return GraphRun("no package " ~ only);
    // A dry run writes nothing (CIC1): no run directory, no dub trap.
    const dry = o.reporting.dryRun || o.explain;
    if (!dry)
        mkdirRecurse(o.into);
    // Oracle 3: every compile under `strace`, its trace beside its manifest.
    if (o.traceCompiles)
    {
        const strace = onPath("strace");
        if (strace is null)
            return GraphRun("tracing compiles needs strace on PATH");
        foreach (ref a; g.plan.graph.actions)
            if (a.kind == ActionKind.compile)
                a.action.match!(
                    (ref ProcessAction pa) {
                        pa.argv = [strace, "-f", "-y", "-qq", "-e", "trace=%file", "-o", "$MEASURE/trace", "--"]
                            ~ pa.argv;
                    },
                    (ref _) {});
    }
    // D39's spike: every build action confined to its own directories and
    // without a network; tests too with `Confinement.tests`, which may also
    // write their temporary directory.
    if (o.confine != Confinement.none)
    {
        import std.process : execute;

        const wrapper = buildPath(o.into, "confine");
        const built = execute([tools.compiler, "-O", "-of=" ~ wrapper, buildPath(root, "apps/ci/tools/confine.d")]);
        if (built.status != 0)
            return GraphRun("cannot build the confinement wrapper: " ~ built.output);
        foreach (ref a; g.plan.graph.actions)
        {
            if (a.kind == ActionKind.test && o.confine != Confinement.tests)
                continue;
            // The dub trap records its calls beside itself, so a confined
            // action that runs dub is still seen (BGX1).
            string[] prefix = [wrapper, "--write=$OUT", "--write=$MEASURE", "--no-network",
                "--write=" ~ buildPath(o.into, "dub-trap")];
            if (a.kind == ActionKind.test)
                prefix ~= "--write=" ~ environment.get("TMPDIR", "/tmp");
            // D39: a test that declares dub (D62) runs it, and dub writes
            // beneath its home: a package's generated files and its cache.
            if (a.kind == ActionKind.test)
                foreach (pkg, granted; g.plan.testTools)
                    if (granted.canFind("dub") && a.id.text.startsWith("test:sparkles." ~ pkg ~ ":"))
                        prefix ~= "--write=" ~ environment.get("DUB_HOME",
                            buildPath(environment.get("HOME", "/"), ".dub"));
            prefix ~= "--";
            a.action.match!(
                (ref ProcessAction pa) { pa.argv = prefix ~ pa.argv; },
                (ref _) {});
        }
    }
    if (o.adjustPlan !is null)
        o.adjustPlan(g.plan);
    // `--build-only`: every test binary's link, with what it needs; with
    // applications planned, all of the plan, their libraries' compiles too.
    if (o.buildOnly && !o.applications.length)
    {
        string[] links;
        foreach (ref a; g.plan.graph.actions)
            if (a.kind == ActionKind.link && (a.id.text.canFind(":test-root:") || a.id.text.canFind(":application:")))
                links ~= a.id.text;
        g.plan.graph = needing(g.plan.graph, links);
    }
    if (o.tasks.length)
    {
        string[] targets;
        foreach (t; o.tasks)
        {
            string why;
            const id = uniqueTask(g.plan.graph, t, why);
            if (!id.length)
                return GraphRun(why);
            targets ~= id;
        }
        g.plan.graph = needing(g.plan.graph, targets);
        string[] replaced;
        foreach (t; o.replaceTasks)
        {
            string why;
            replaced ~= uniqueTask(g.plan.graph, t, why);
        }
        o.replaceTasks = replaced;
    }
    // Generators and tests run with the environment they are given here,
    // declared whole (BGX1): the driver's own, with a `dub` first on `PATH`
    // that records each call and fails (oracle 11 step 1).
    const trap = buildPath(o.into, "dub-trap");
    const declared = dry ? null : declaredEnvironment(trap);
    auto layout = RunLayout(root, o.into, o.cache, g.toolchain.identity, o.check);
    layout.requireCached = o.requireCached.dup;
    layout.explain = o.explain;
    layout.checkTasks = o.checkTasks.dup;
    layout.replaceTasks = o.replaceTasks.dup;
    layout.hashSample = o.hashSample;
    g.into = o.into;
    auto nodes = executionNodes(g.plan.graph, layout, declared);
    // D62: a test that declares `dub` runs with the real one first on its
    // `PATH`; every other test meets the trap.
    foreach (ref n; nodes)
        if (n.id.text.startsWith("test:"))
            foreach (pkg, granted; g.plan.testTools)
                if (granted.canFind("dub") && n.id.text.startsWith("test:sparkles." ~ pkg ~ ":"))
                {
                    auto action = n.action;
                    action.match!(
                        (ref ProcessAction pa) {
                            foreach (ref e; pa.envDelta)
                                if (e.name == "PATH")
                                    e.value = environment.get("PATH", "");
                        },
                        (ref _) {});
                    (() @trusted { n.action = action; })();
                }
    // CIC11: each test leg through the runner core, in this process; and the
    // client's own actions.
    InProcessHandler[string] handlers;
    foreach (name, handler; o.handlers)
        handlers[name] = handler;
    if (o.runnerCore)
    {
        import test_leg : legAction, legHandler, runTestLeg;

        if (o.confine == Confinement.tests)
            return GraphRun("the runner core's tests cannot run confined yet");
        handlers[legHandler] = (ref TaskContext!Sched ctx, const ref InProcessAction a) => runTestLeg(ctx, a);
        // A package beneath the runner (`metadata`, `test-harness`, …) cannot
        // depend on it: its binary runs its own tests, and its exit status is
        // the verdict, as under `dub test`.
        // The packages whose recipes depend on the runner, from the schema.
        bool[string] speaking;
        {
            const workspace = readWorkspaceAt(root);
            if (workspace.hasValue)
                foreach (ref r; workspace.value.recipes)
                {
                    bool depends = r.manifest.dependencies.any!(d => d.name == "sparkles:test-runner");
                    foreach (ref c; r.manifest.configurations)
                        depends |= c.dependencies.any!(d => d.name == "sparkles:test-runner");
                    speaking[r.manifest.name] = depends;
                }
        }
        bool speaksProtocol(string task)
        {
            const parts = task.split(":");
            const pkg = parts.length > 1 ? parts[1].replace("sparkles.", "") : null;
            return speaking.get(pkg, true);
        }
        foreach (ref n; nodes)
            if (n.id.text.startsWith("test:") && speaksProtocol(n.id.text))
            {
                auto action = n.action;
                auto leg = action.match!(
                    (ref ProcessAction pa) => TaskAction(legAction(pa)),
                    (ref _) => action);
                (() @trusted { n.action = leg; })();
            }
    }
    if (o.adjustExecution !is null)
        foreach (ref n; nodes)
        {
            auto action = n.action;
            action.match!(
                (ref ProcessAction pa) { o.adjustExecution(n.id.text, pa); },
                (ref _) {});
            (() @trusted { n.action = action; })();
        }
    static struct Tee
    {
        typeof(appender!string())* log;
        bool echo;
        void put(T)(T s)
        {
            import std.stdio : stdout;

            log.put(s);
            if (echo)
                stdout.write(s);
        }
    }
    auto log = appender!string;
    auto w = Tee(&log, o.echo);
    const r = runActions(nodes, g.plan.graph, layout, w, o.jobs ? o.jobs : logicalProcessors, &g.stats,
        o.failFast, handlers, o.reporting);
    g.exitCode = r.exitCode;
    g.log = log.data;
    // BGS5: eviction after the run, off its publish path.
    if (o.cache.length && !dry)
    {
        import sparkles.build_graph.execute : storeOperation;

        auto discard = appender!string;
        cast(void) storeOperation(o.cache, "evict", discard);
    }
    if (exists(buildPath(trap, "calls")))
        g.dubCalls = readText(buildPath(trap, "calls"));
    // BGS9: the check's outputs are a private store, discarded after it.
    if (o.check && exists(o.into))
    {
        import std.file : rmdirRecurse;

        rmdirRecurse(o.into);
    }
    return g;
}

int runPackage(string root, string only, string into, string cache, bool checkDeterminism = false,
    Confinement confine = Confinement.none)
{
    // Oracle 3 over an earlier traced run's directory, running nothing.
    if (oracle3Only)
    {
        Tools tools;
        Toolchain toolchain;
        if (const why = pathTools(tools, toolchain))
        {
            stderr.writeln("plan-graph: ", why);
            return 2;
        }
        auto p = planRepository(root, false, only, tools, toolchain.identity);
        if (p.error.length)
        {
            stderr.writeln("plan-graph: ", p.error);
            return 1;
        }
        return reportOracle3(p, root, into);
    }
    auto g = runGraph(root, only, RunOptions(into: into, cache: cache, check: checkDeterminism, confine: confine,
        traceCompiles: traceCompiles, jobs: runJobs, echo: true, runnerCore: runnerCore));
    if (g.error.length)
    {
        stderr.writeln("plan-graph: ", g.error);
        return g.error.startsWith("no package") ? 2 : 1;
    }
    writeln(g.plan.graph.actions.length, " actions; exit ", g.exitCode);
    if (cache.length)
        writeln("store ", cache, ": ", g.stats.summary);
    if (g.dubCalls.length)
    {
        stderr.writeln("plan-graph: BGX1: a test ran dub: ", g.dubCalls);
        return 1;
    }
    writeln("BGX1: no test ran dub");
    if (traceCompiles && reportOracle3(g.plan, root, into) != 0)
        return 1;
    return g.exitCode;
}

// Oracle 3's verdict over a traced run's directory.
int reportOracle3(ref const Planned p, string root, string into)
{
    size_t compiles, opened, lookups;
    const failures = manifestCompleteness(p.graph, root, into, compiles, opened, lookups);
    foreach (f; failures[0 .. failures.length < 40 ? $ : 40])
        writeln("oracle 3: ", f);
    writeln(failures.length ? "fail" : "pass", " oracle 3 (manifest completeness): ", compiles, " compiles, ",
        opened, " files opened, ", lookups, " failed lookups under their roots; ", failures.length, " failures");
    return failures.length ? 1 : 0;
}

/// The toolchain as a run names it (§8).
struct Toolchain
{
    string identity; /// the digest of BGT1's components: store closures (BGT2) and host files (BGT3)
    string config;   /// the compiler's configuration file (BGT1)
    string root;     /// the compiler's own tree, holding druntime's and Phobos' sources
}

/*
§8: the compiler reports its configuration file and where `object` lies,
so the run passes the one explicitly and remaps the other's tree (BGA11).
The identity covers BGT1's components but the test runner, which keys only
a test action: every tool the run names, the configuration's import and library directories
(druntime's and Phobos' sources and libraries), and the C compiler's
startup objects, C library and system include directories, as it reports
them. Each that resolves into the Nix store is named by its store-path
closure (BGT2); each other file by its digest, each other directory by the
digest of its files (BGT3).
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
    // The test runner's core keys a test action (BGT1), and E3 keys no test
    // (BGX2): in this identity it would change every build action's key
    // with the runner, which none of them reads.
    string[] files = [tools.compiler, t.config, tools.cc, tools.linker, tools.archiver, tools.fail,
        tools.deviceCompiler];
    foreach (tool; tools.shaderTools)
        files ~= tool[1];
    string[] trees = configDirectories(t.config);
    if (tools.cc.length)
    {
        files ~= cRuntimeFiles(tools.cc);
        trees ~= cIncludeDirectories(tools.cc);
    }
    import std.functional : toDelegate;

    t.identity = hexOf(sha256Of(identityListing(files, trees, toDelegate(&storeClosure))));
    return t;
}

// The directories an LDC configuration (a file, or a directory of them) names: its `-I` import roots
// (druntime's and Phobos' sources) and its library directories.
string[] configDirectories(string config)
{
    import std.file : exists, isDir, readText;

    string[] dirs;
    if (!config.length || !exists(config))
        return dirs;
    // A configuration may be a directory of files, as Nix's LDC has it.
    string text_;
    if (isDir(config))
    {
        string[] names;
        foreach (e; dirEntries(config, SpanMode.depth))
            if (e.isFile)
                names ~= e.name;
        foreach (name; names.sort)
            text_ ~= readText(name) ~ "\n";
    }
    else
        text_ = readText(config);
    for (size_t i; i < text_.length; ++i)
    {
        if (text_[i] != '"')
            continue;
        size_t j = i + 1;
        while (j < text_.length && text_[j] != '"')
            ++j;
        auto s = text_[i + 1 .. j];
        i = j;
        if (s.startsWith("-I="))
            s = s[3 .. $];
        else if (s.startsWith("-I"))
            s = s[2 .. $];
        else if (s.startsWith("-L-L"))
            s = s[4 .. $];
        if (s.startsWith("/") && !s.canFind('%') && exists(s) && isDir(s) && !dirs.canFind(s))
            dirs ~= s.idup;
    }
    return dirs;
}

// The C compiler's startup objects and C library, as it resolves them in the
// environment a build action has, which is cleared (BGA4): the dev shell's
// wrapper adds every package's headers through `NIX_CFLAGS_COMPILE`.
string[] cRuntimeFiles(string cc)
{
    import std.process : Config, execute;
    import std.string : lineSplitter, strip;

    string[] found;
    foreach (name; ["crt1.o", "crti.o", "crtn.o", "Scrt1.o", "libc.so", "libc.a", "libgcc.a"])
    {
        const r = execute([cc, "-print-file-name=" ~ name], null, Config.newEnv);
        const path = r.output.strip;
        // A name it cannot resolve comes back bare.
        if (r.status == 0 && path.startsWith("/"))
            found ~= path.idup;
    }
    return found;
}

// The directories the C compiler searches for `#include <…>`, in a build
// action's cleared environment.
string[] cIncludeDirectories(string cc)
{
    import std.process : Config, execute;
    import std.string : lineSplitter, strip;

    string[] dirs;
    bool inList;
    foreach (line; execute([cc, "-E", "-v", "-x", "c", "/dev/null", "-o", "/dev/null"], null, Config.newEnv)
            .output.lineSplitter)
    {
        if (line.startsWith("#include <...> search starts here:"))
            inList = true;
        else if (line.startsWith("End of search list."))
            break;
        else if (inList && line.strip.startsWith("/"))
            dirs ~= line.strip.idup;
    }
    return dirs;
}

// The store-path closure of `paths` (BGT2), sorted; null when it cannot be
// queried, as without Nix.
string[] storeClosure(const string[] paths)
{
    import std.process : execute;
    import std.string : lineSplitter;

    if (!paths.length)
        return [];
    const r = execute(["nix-store", "--query", "--requisites"] ~ paths);
    return r.status == 0 ? r.output.lineSplitter.map!(l => l.idup).array.sort.release : null;
}

/**
The text a toolchain identity digests (BGT1–BGT3): each component of
`files` and `trees` that resolves into the Nix store, by the sorted closure
`closure` gives of them all; each other file as `file <digest> <path>`, each
other directory as `tree <digest> <path>` (the digest of its files' paths and
digests, sorted), and a component that is not there as `absent <path>`.
Without a closure (no Nix), store paths are read as host ones.
*/
string identityListing(const string[] files, const string[] trees, scope string[] delegate(const string[]) closure)
{
    import std.file : exists, isDir, isFile, read;
    import sparkles.base.hash.blake3 : blake3;
    import sparkles.build_graph.store : hexOf;

    static string resolved(string path)
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;

        auto r = (() @trusted => realpath(path.toStringz, null))();
        if (r is null)
            return path;
        scope (exit)
            (() @trusted => free(r))();
        return (() @trusted => r.fromStringz.idup)();
    }
    static string fileDigest(string path) => hexOf(blake3(cast(const(ubyte)[]) read(path)));
    static string treeDigest(string dir)
    {
        string[] entries;
        foreach (e; dirEntries(dir, SpanMode.depth))
            if (e.isFile)
                entries ~= e.name ~ " " ~ fileDigest(e.name);
        return hexOf(blake3(cast(const(ubyte)[]) entries.sort.release.join("\n")));
    }

    string[] store, host;
    bool[string] isTree;
    foreach (i, p; files ~ trees)
    {
        if (!p.length)
            continue;
        const r = resolved(p);
        isTree[r] = i >= files.length;
        (r.startsWith("/nix/store/") ? store : host) ~= r;
    }
    string[] lines;
    if (store.length)
    {
        const c = closure(store);
        if (c is null)
            host ~= store;
        else
            lines ~= c;
    }
    foreach (p; host)
        lines ~= !exists(p) ? "absent " ~ p
            : isTree[p] && isDir(p) ? "tree " ~ treeDigest(p) ~ " " ~ p
            : "file " ~ fileDigest(p) ~ " " ~ p;
    return lines.sort.uniq.array.join("\n");
}

/// A host component is named by its contents, a store one by its closure,
/// and both kinds may mix (BGT2, BGT3).
@("graph_driver.identityListing.hostAndStore")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.process : thisProcessID;

    const made = buildPath(tempDir, text("toolchain-identity-test-", thisProcessID));
    mkdirRecurse(buildPath(made, "include", "sys"));
    scope (exit)
        rmdirRecurse(made);
    // The listing names a path resolved: macOS's temporary directory is
    // beneath `/var`, a link to `/private/var`.
    const dir = () @trusted {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;

        auto r = realpath(made.toStringz, null);
        assert(r !is null, made);
        scope (exit)
            free(r);
        return r.fromStringz.idup;
    }();
    write(buildPath(dir, "cc"), "#!/bin/sh\n");
    write(buildPath(dir, "include", "sys", "types.h"), "typedef int t;\n");
    string[] queried;
    string[] closure(const string[] paths)
    {
        queried = paths.dup;
        return ["/nix/store/aaa-ldc"];
    }
    const files = [buildPath(dir, "cc"), "/nix/store/aaa-ldc/bin/ldc2", buildPath(dir, "gone")];
    const trees = [buildPath(dir, "include")];
    const before = identityListing(files, trees, &closure);
    assert(queried == ["/nix/store/aaa-ldc/bin/ldc2"]);
    assert(before.canFind("/nix/store/aaa-ldc\n"));
    assert(before.canFind("absent " ~ buildPath(dir, "gone")));
    assert(before.canFind(" " ~ buildPath(dir, "cc")) && before.canFind("tree "));

    // An edited host header changes the identity; so does an edited tool.
    write(buildPath(dir, "include", "sys", "types.h"), "typedef long t;\n");
    const header = identityListing(files, trees, &closure);
    assert(header != before);
    write(buildPath(dir, "cc"), "#!/bin/sh\nexit 0\n");
    assert(identityListing(files, trees, &closure) != header);

    // Without Nix, a store path is read as a host one.
    string[] none(const string[]) => null;
    assert(identityListing([buildPath(dir, "cc"), "/nix/store/aaa-ldc/bin/ldc2"], null, &none)
        .canFind("absent /nix/store/aaa-ldc/bin/ldc2"));
}


/**
BGS7's operations on the store beneath `cache`, behind `ci cache stats`,
`list`, `gc`, `verify` and `remove`: `size`, `list`, `gc`, `verify`, `evict[=<results bytes>]`,
and `remove-key=`, `remove-task=`, `remove-package=` or
`remove-toolchain=` a value.
*/
int cacheOp(string cache, string op)
{
    import std.stdio : stdout;
    import sparkles.build_graph.execute : storeOperation;

    auto w = stdout.lockingTextWriter;
    return storeOperation(cache, op, w);
}

/// With `--fetch-sources`: the registry sources the run fetched (BGR4),
/// which planning reads in place of `SPARKLES_DUB_SOURCES`'s.
__gshared string fetchedSources;

/**
BGR4 without Nix: fetches the packages the dub lockfiles pin into
`<cache>/build/v1/sources`, verified by the locks' hashes. Archives come
through `curl`, repositories through a shallow `git fetch` of the pinned
commit. Returns the sources directory, or null after printing why not.
*/
string fetchSources(string root, string cache)
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.build_graph.fetch : Fetcher, fetchLockedSources;
    import sparkles.event_horizon.sys : BlockingVfs;
    import std.file : mkdirRecurse;
    import std.process : execute;

    const sourcesPath = buildPath(cache, "build", "v1", "sources");
    mkdirRecurse(sourcesPath);
    auto tree = systemTree();
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")],
        tree);
    if (locked.hasError)
    {
        stderr.writeln("plan-graph: ", locked.error);
        return null;
    }
    auto vfs = new BlockingVfs;
    auto sources = openRoot!(Rights.all)(vfs, sourcesPath, ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
    if (sources.hasError)
    {
        stderr.writeln("plan-graph: cannot open ", sourcesPath);
        return null;
    }
    const curl = onPath("curl");
    auto fetcher = Fetcher(
        (string url, string destination) => curl !is null
            && execute([curl, "-sSfL", "--retry", "2", "-o", destination, url]).status == 0,
        (string url, string commit, string destination) {
            mkdirRecurse(destination);
            return runGit(["init", "-q"], destination).status == 0
                && runGit(["fetch", "-q", "--depth", "1", url, commit], destination).status == 0
                && runGit(["-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD"], destination).status == 0;
        },
        // As nixpkgs' `importDubLock` does: `dub fetch` from a registry of
        // the one archive, which places the package as dub holds it.
        (string name, string version_, string archive, string destination) {
            import std.file : copy, exists, rename, rmdirRecurse;

            const dub = onPath("dub");
            const registry = destination ~ ".registry/" ~ name;
            const home = destination ~ ".home";
            mkdirRecurse(registry);
            scope (exit)
                foreach (dir; [destination ~ ".registry", home])
                    if (dir.exists)
                        rmdirRecurse(dir);
            copy(archive, buildPath(registry, name ~ "-" ~ version_ ~ ".zip"));
            if (dub is null || execute([dub, "fetch", name ~ "@" ~ version_, "--cache=user", "--skip-registry=standard",
                    "--registry=file://" ~ registry], ["DUB_HOME": home]).status != 0)
                return false;
            const placed = buildPath(home, "packages", name, version_, name);
            if (!placed.exists)
                return false;
            rename(placed, destination);
            return true;
        });
    if (const why = fetchLockedSources(locked.value, sources.value, sourcesPath, fetcher))
    {
        stderr.writeln("plan-graph: ", why);
        return null;
    }
    return sourcesPath;
}

/**
Oracle 3, manifest completeness: each compile of a `--trace-compiles` run
ran under `strace`, and its trace is compared with the manifest its
dependency output gave. Every file it opened for reading, the toolchain's
store paths and the host's `/etc`, `/proc`, `/sys` and `/dev` aside, must
be a file of the manifest; every lookup that failed beneath one of its
import or string import roots must be an absent candidate or a directory
one lies beneath; and every write, rename or removal must fall inside its
own output and measurement directories (invariant 6). Returns the
failures, one per line; empty when the oracle holds.
*/
string[] manifestCompleteness(const ActionGraph g, string root, string runDirectory, out size_t compiles,
    out size_t opened, out size_t failedLookups)
{
    import std.file : exists, isDir, readText;
    import std.string : lineSplitter;
    import sparkles.build_graph.execute : RunLayout, makeRulePrerequisites;

    const layout = RunLayout(root, runDirectory);
    string[] failures;
    string absolute(string p) => p.startsWith("$RUN/") ? runDirectory ~ p[4 .. $]
        : p.startsWith("/") ? p : buildPath(root, p);
    foreach (ref a; g.actions)
    {
        if (a.kind != ActionKind.compile)
            continue;
        const measure = layout.measureOf(a.id), out_ = layout.outOf(a.id);
        const tracePath = buildPath(measure, "trace");
        if (!tracePath.exists)
            continue; // reused, or not traced
        ++compiles;
        bool[string] files, absent;
        foreach (line; readText(buildPath(measure, "digests")).lineSplitter)
            if (line.length > 66)
                files[buildNormalizedPath(absolute(line[66 .. $]))] = true;
        foreach (p; makeRulePrerequisites(readText(buildPath(measure, "absent"))))
            absent[buildNormalizedPath(absolute(p))] = true;
        string[] roots, cRoots;
        a.action.match!(
            (ref const ProcessAction p) {
                foreach (arg; p.argv)
                    foreach (prefix; ["-I=", "-J="])
                        if (arg.startsWith(prefix) && !arg[prefix.length .. $].startsWith("$"))
                            roots ~= buildNormalizedPath(absolute(arg[prefix.length .. $]));
                // The C roots the key covers whole (BGK2): a C source's own
                // directory and each C include root in the worktree.
                foreach (arg; p.argv)
                    if (arg.startsWith("-P-I") && !arg[4 .. $].startsWith("/"))
                        cRoots ~= buildNormalizedPath(absolute(arg[4 .. $]));
                    else if (arg.length > 2 && arg[0] != '-' && !arg.startsWith("/")
                            && (arg.endsWith(".c") || arg.endsWith(".i")))
                        cRoots ~= buildNormalizedPath(absolute(arg)).dirName;
                // LDC hands the preprocessor the D import roots too.
                if (cRoots.length)
                    cRoots ~= roots;
            },
            (ref const _) {});
        bool underAbsent(string path)
        {
            if (path in absent)
                return true;
            foreach (k, _; absent)
                if (k.startsWith(path ~ "/"))
                    return true;
            return false;
        }
        bool ours(string path) => path.startsWith(out_ ~ "/") || path == out_
            || path.startsWith(measure ~ "/") || path == measure || path.startsWith("/dev/");
        bool host(string path) => ["/nix/store/", "/etc/", "/proc/", "/sys/", "/dev/"].canFind!(h => path.startsWith(h));
        foreach (ref e; parseTrace(readText(tracePath), root))
        {
            if (e.path.length == 0)
                continue;
            const writes = e.call.canFind("rename") || e.call.canFind("unlink") || e.call.canFind("mkdir")
                || e.call.canFind("rmdir") || ((e.call == "openat" || e.call == "open")
                    && (e.args.canFind("O_WRONLY") || e.args.canFind("O_RDWR") || e.args.canFind("O_CREAT")));
            if (writes)
            {
                if (!ours(e.path))
                    failures ~= text(a.id.text, ": writes outside its directories: ", e.call, " ", e.path);
                continue;
            }
            if ((e.call == "openat" || e.call == "open") && e.ok && !e.args.canFind("O_DIRECTORY"))
            {
                if (host(e.path) || ours(e.path) || (e.path.exists && e.path.isDir))
                    continue;
                ++opened;
                // A path the manifest names through a link names the same bytes.
                if (e.path !in files)
                    failures ~= text(a.id.text, ": read but not in the manifest: ", e.path);
                continue;
            }
            if (!e.ok && e.ret.canFind("ENOENT") && roots.canFind!(r => e.path.startsWith(r ~ "/")))
            {
                ++failedLookups;
                if (!underAbsent(e.path) && !cRoots.canFind!(r => e.path.startsWith(r ~ "/")))
                    failures ~= text(a.id.text, ": a failed lookup that is no absent candidate: ", e.path);
            }
        }
    }
    return failures;
}

/**
The tools a run names, each found on `PATH` by absolute path, and their
identity (§8): the compiler's configuration passed explicitly, its own tree
remapped to `/ldc` (BGA11), the fork's dependency output used when the
compiler has it. Returns null, or why the tools cannot be named.
*/
string pathTools(out Tools tools, out Toolchain toolchain)
{
    import std.process : execute;

    tools = Tools(compiler: onPath(compilerName), archiver: onPath("ar"), cc: onPath("cc"), linker: onPath("ld.lld"),
        fail: onPath("false"), deviceCompiler: onPath("ldc2-vulkan"));
    foreach (name; ["spirv-val", "spirv-opt", "spirv-dis", "spirv-as", "spirv-cross", "glslangValidator"])
        tools.shaderTools ~= [name, onPath(name)];
    if (tools.compiler is null || tools.archiver is null || tools.cc is null || tools.linker is null)
        return compilerName ~ ", ar, cc and ld.lld must be on PATH";
    // The fork's dependency output, which a compile's manifest comes from.
    const help = execute([tools.compiler, "--help-hidden"]);
    tools.dependencyOutput = help.output.canFind("makedeps-digests") && !noDependencyOutput;
    toolchain = toolchainOf(tools);
    tools.config = toolchain.config;
    if (testTimeout != Duration.max)
        tools.testLimit = testTimeout;
    // The library directories a C driver finds through `$LIBRARY_PATH`, and
    // the `-L` ones Nix's compiler wrapper adds from `$NIX_LDFLAGS`.
    foreach (dir; environment.get("LIBRARY_PATH", "").split(":"))
        if (dir.length && !tools.libraryPath.canFind(dir))
            tools.libraryPath ~= dir;
    foreach (flag; environment.get("NIX_LDFLAGS", "").split(" "))
        if (flag.startsWith("-L") && flag.length > 2 && !tools.libraryPath.canFind(flag[2 .. $]))
            tools.libraryPath ~= flag[2 .. $];
    if (toolchain.root.length)
        tools.prefixMaps = [toolchain.root ~ "=/ldc"];
    return null;
}

/**
The environment a run declares to its generators and tests (BGX1): the
driver's own, with a `dub` first on `PATH` that records each call beside
itself, in `trap`, and fails, so an action that runs dub is seen.
*/
EnvEntry[] declaredEnvironment(string trap)
{
    import std.file : mkdirRecurse, setAttributes, write;

    mkdirRecurse(trap);
    write(buildPath(trap, "dub"), "#!/bin/sh\necho \"$@\" >> '" ~ buildPath(trap, "calls") ~ "'\nexit 1\n");
    setAttributes(buildPath(trap, "dub"), octal!755);
    EnvEntry[] declared;
    foreach (name, value; environment.toAA)
        declared ~= EnvEntry(name, name == "PATH" ? trap ~ ":" ~ value : value);
    declared.sort!((a, b) => a.name < b.name);
    return declared;
}

/**
`ci cache explain <task>` (BGS8): plans the repository's test
selection with the tools a run would name, and looks `task` up, with each
action it needs, as a run beneath `cache` would, executing nothing and
publishing nothing. `task` is an id, or a prefix only one id has.

Writes to `writer` what each action reached would do, in the order reached
(a hit, a digest record serving it, a miss and its class with what
differs), then the task's own line: its verdict, or, when a prerequisite
misses, that it is not reached and why. Returns 0, or 2 when the task is
unknown or ambiguous, or the repository cannot be planned.
*/
int explainTask(W)(string root, string cache, string task, ref W writer)
{
    import std.datetime.systime : Clock;
    import std.file : exists, mkdirRecurse, rmdirRecurse;
    import std.process : thisProcessID;
    import sparkles.build_graph.execute : RunLayout, RunStats, executionNodes, runActions;

    void say(string line) { writer.put(line); writer.put("\n"); }

    Tools tools;
    Toolchain toolchain;
    if (const why = pathTools(tools, toolchain))
    {
        say("explain: " ~ why);
        return 2;
    }
    auto p = planRepository(root, false, null, tools, toolchain.identity);
    if (p.error.length)
    {
        say("explain: " ~ p.error);
        return 2;
    }
    string[] matches;
    foreach (ref a; p.graph.actions)
        if (a.id.text == task)
        {
            matches = [a.id.text];
            break;
        }
        else if (a.id.text.startsWith(task))
            matches ~= a.id.text;
    if (matches.length != 1)
    {
        say(matches.length ? text("explain: ", matches.length, " tasks start with ", task, ": ",
            matches[0 .. matches.length < 5 ? $ : 5].join(", "), matches.length > 5 ? ", …" : "")
            : "explain: no task " ~ task);
        return 2;
    }
    const target = matches[0];

    // The task and every action it needs, through any edge.
    bool[string] needed = [target: true];
    for (bool grew = true; grew;)
    {
        grew = false;
        foreach (ref e; p.graph.edges)
            if (e.dependent.text in needed && e.prerequisite.text !in needed)
            {
                needed[e.prerequisite.text] = true;
                grew = true;
            }
    }
    ActionGraph sub;
    sub.actions = p.graph.actions.filter!(a => (a.id.text in needed) !is null).array;
    sub.edges = p.graph.edges.filter!(e => (e.prerequisite.text in needed) !is null
        && (e.dependent.text in needed) !is null).array;

    const runDir = buildPath(cache, "runs", text("explain-", Clock.currTime.toUnixTime, "-", thisProcessID));
    mkdirRecurse(runDir);
    scope (exit)
        if (exists(runDir))
            rmdirRecurse(runDir);
    auto layout = RunLayout(root, runDir, cache, toolchain.identity);
    layout.explain = true;
    auto nodes = executionNodes(sub, layout, declaredEnvironment(buildPath(runDir, "dub-trap")));
    static struct Discard
    {
        void put(T)(T) {}
    }
    Discard quiet;
    RunStats stats;
    cast(void) runActions(nodes, sub, layout, quiet, logicalProcessors, &stats);

    string verdict;
    string[] misses;
    foreach (line; stats.explained)
    {
        say(line);
        if (line.startsWith(target ~ ": "))
            verdict = line;
        else if (line.canFind(": miss (") || line.canFind(": has no key") || line.canFind(": would run"))
            misses ~= line;
    }
    say(verdict.length ? "explain " ~ verdict : text("explain ", target, ": not reached: ",
        misses.length ? misses.join("; ") : "a prerequisite did not complete"));
    return 0;
}

/**
The id of `g`'s task named `task`: that id, or the one id it is a prefix of.
Null, with `why` saying so, when no id or several match.
*/
string uniqueTask(ref const ActionGraph g, string task, out string why)
{
    string[] matches;
    foreach (ref a; g.actions)
        if (a.id.text == task)
            return a.id.text;
        else if (a.id.text.startsWith(task))
            matches ~= a.id.text;
    if (matches.length == 1)
        return matches[0];
    why = matches.length ? text(matches.length, " tasks start with ", task, ": ",
        matches[0 .. matches.length < 5 ? $ : 5].join(", "), matches.length > 5 ? ", …" : "")
        : "no task " ~ task;
    return null;
}

/// `g` cut to the tasks `targets` and every action they need, through any edge.
ActionGraph needing(ref ActionGraph g, const string[] targets)
{
    bool[string] needed;
    foreach (t; targets)
        needed[t] = true;
    for (bool grew = true; grew;)
    {
        grew = false;
        foreach (ref e; g.edges)
            if (e.dependent.text in needed && e.prerequisite.text !in needed)
            {
                needed[e.prerequisite.text] = true;
                grew = true;
            }
    }
    ActionGraph sub;
    foreach (ref a; g.actions)
        if (a.id.text in needed)
            sub.actions ~= a;
    foreach (ref e; g.edges)
        if (e.prerequisite.text in needed && e.dependent.text in needed)
            sub.edges ~= e;
    return sub;
}

/**
`ci cache replace <task>` (BGS7): plans the repository's test selection
with the tools a run would name, and executes `task` (an id, or a prefix only
one id has) with its lookup bypassed, after looking up or building what it
needs; its result replaces the published one, which moves to `trash/`. A live
lease another process holds keeps the published result, and is reported.
Returns 0, 1 when the task failed or a lease held the replacement back, or 2
when the task is unknown or ambiguous.
*/
/**
What `ci test` records of its last run beneath the cache (`runs/last-ci-test.json`)
for `ci cache verify --rerun`: the selection it planned and each action's
result key.
*/
struct LastRun
{
    string[] packages;  ///
    TestLeg[] legs;     ///
    bool coverage;      ///
    bool buildOnly;     ///
    string[string] resultKeys; ///
}

/// Writes `run` as the cache's last run.
void recordLastRun(string cache, const LastRun run)
{
    import std.file : mkdirRecurse, write;
    import std.json : JSONValue;

    JSONValue[] legs;
    foreach (l; run.legs)
        legs ~= JSONValue(["threads": JSONValue(l.threads), "skipSlow": JSONValue(l.skipSlow),
            "name": JSONValue(l.name)]);
    JSONValue keys = JSONValue.emptyObject;
    foreach (t, k; run.resultKeys)
        keys[t] = k;
    auto j = JSONValue(["packages": JSONValue(run.packages), "legs": JSONValue(legs),
        "coverage": JSONValue(run.coverage), "buildOnly": JSONValue(run.buildOnly), "resultKeys": keys]);
    mkdirRecurse(buildPath(cache, "runs"));
    write(buildPath(cache, "runs", "last-ci-test.json"), j.toString);
}

/// The cache's last run; null `why` when there is one.
LastRun lastRun(string cache, out string why)
{
    import std.file : exists, readText;
    import std.json : JSONException, JSONType, parseJSON;

    LastRun run;
    const file = buildPath(cache, "runs", "last-ci-test.json");
    if (!exists(file))
    {
        why = "no `ci test` run is recorded beneath " ~ cache;
        return run;
    }
    try
    {
        const j = parseJSON(readText(file));
        foreach (p; j["packages"].array)
            run.packages ~= p.str;
        foreach (l; j["legs"].array)
            run.legs ~= TestLeg(cast(uint) l["threads"].integer, l["skipSlow"].type == JSONType.true_,
                l["name"].str);
        run.coverage = j["coverage"].type == JSONType.true_;
        run.buildOnly = j["buildOnly"].type == JSONType.true_;
        foreach (t, k; j["resultKeys"].object)
            run.resultKeys[t] = k.str;
    }
    catch (JSONException e)
        why = file ~ ": " ~ e.msg;
    return run;
}

/**
`ci cache verify --rerun` (BGS9, CIC13): re-plans the last `ci test` run's
selection and re-executes `tasks`, or else CIC13's sample of `n` compiles
and `n` other actions by `HEAD`, each with its lookup bypassed into a private
store; a result whose outputs differ is removed, and fails the check.
*/
int rerunCheck(W)(string root, string cache, size_t n, const string[] tasks, ref W writer)
{
    import sparkles.build_graph.execute : determinismSample;
    import sparkles.build_primitives.git_env : runGitStdout;
    import std.datetime.systime : Clock;
    import std.process : thisProcessID;
    import std.string : lineSplitter, strip;

    void say(string line) { writer.put(line); writer.put("\n"); }

    string why;
    const run = lastRun(cache, why);
    if (why.length)
    {
        say("verify --rerun: " ~ why);
        return 2;
    }
    const head = runGitStdout(["rev-parse", "HEAD"], root);
    auto sample = tasks.length ? tasks.dup : determinismSample(run.resultKeys, head.output.strip, n);
    if (!sample.length)
    {
        say("verify --rerun: the last run has no cacheable action to check");
        return 0;
    }
    auto g = runGraph(root, null, RunOptions(into: buildPath(cache, "runs",
        text("check-", Clock.currTime.toUnixTime, "-", thisProcessID)), cache: cache, check: true,
        checkTasks: sample, packages: run.packages.dup, legs: run.legs.dup, coverage: run.coverage,
        buildOnly: true));
    if (g.error.length)
    {
        say("verify --rerun: " ~ g.error);
        return 2;
    }
    foreach (line; g.log.lineSplitter)
        if (line.canFind("nondeterministic"))
            say(line.idup);
    const differing = g.stats.misses.get("nondeterministic", 0);
    say(text("verify --rerun: ", sample.length, " action(s) re-executed, ", differing, " differed",
        differing ? "; their results are removed" : ""));
    return differing || g.exitCode != 0 ? 1 : 0;
}

int replaceTask(W)(string root, string cache, string task, ref W writer)
{
    import std.datetime.systime : Clock;
    import std.process : thisProcessID;

    void say(string line) { writer.put(line); writer.put("\n"); }

    auto g = runGraph(root, null, RunOptions(into: buildPath(cache, "runs",
        text("replace-", Clock.currTime.toUnixTime, "-", thisProcessID)), cache: cache, tasks: [task],
        replaceTasks: [task]));
    if (g.error.length)
    {
        say("replace: " ~ g.error);
        return 2;
    }
    string why;
    const target = g.plan.graph.actions.length ? uniqueTask(g.plan.graph, task, why) : null;
    const key = g.stats.resultKeys.get(target, null);
    const held = g.log.canFind("waits for a live lease");
    say(g.exitCode != 0 ? text("replace ", target, ": the action failed; the published result stays")
        : held ? text("replace ", target, ": a live lease another process holds keeps the published result")
        : text("replace ", target, ": published ", key, "; the result it replaced is in trash/"));
    return g.exitCode != 0 || held ? 1 : 0;
}
