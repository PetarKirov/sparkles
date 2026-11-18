/**
The build graph's driver for this repository (build-graph PLAN, E3): plans
the test selection, or one package's test root, and runs it on the
task-DAG executor against the shared store, with the toolchain from `PATH`
named by absolute path (§8).

`ci` drives it (`ci cache store explain`, `ci commits build-each`), and so
does the test-only planner, `apps/ci/tools/plan-graph.d`, whose `--check`
and `--run=` verify E2's and E3's gates through it.

Needs the dev shell's `SPARKLES_DUB_SOURCES` for the registry packages, or
the sources `--fetch-sources` fetched (BGR4).
*/
module graph_driver;


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
import sparkles.build_primitives.task.action : EnvEntry, InProcessAction, InertAction, ProcessAction;
import sparkles.build_primitives.workspace.discovery : ReadKind, ReadSet, readWorkspaceAt;
import sparkles.build_primitives.workspace.package_graph : RecipeRole, buildPackageGraph;
import sparkles.unittest_layout.lint : checkLayout;

enum host = ["linux", "posix"];

BuildPlatform platform() @safe => BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2113, "1.43.0");

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
    // D61: the programs each test runs, declared beside its package's recipe,
    // planned as requests of their own whose tests do not run.
    TestProgram[] programs;
    {
        import std.json : JSONException, JSONType, parseJSON;

        string[] testDirectories;
        foreach (ref pkg; graph.value.packages)
            if (!only.length || pkg.shortName == only)
                testDirectories ~= pkg.path.length ? root ~ "/" ~ pkg.path : root;
        foreach (ti, dir; testDirectories)
        {
            const file = dir ~ "/test-programs.json";
            string json;
            if (!tree.readText(file, json))
                continue;
            try
            {
                foreach (entry; parseJSON(json)["programs"].array)
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
                    programs ~= TestProgram(test: ti, program: rs.length - 1, variable: entry["variable"].str);
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

    auto g = planActions(p.plan, rs, root, tools, null, programs);
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

unittest
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

int runPackage(string root, string only, string into, string cache, bool checkDeterminism = false,
    Confinement confine = Confinement.none)
{
    import std.file : mkdirRecurse;
    import std.parallelism : totalCPUs;
    import std.stdio : stdout;
    import sparkles.build_graph.execute : RunLayout, executionNodes, runActions;

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
    if (p.requests == 0)
    {
        stderr.writeln("plan-graph: no package ", only);
        return 2;
    }
    mkdirRecurse(into);
    // Oracle 3 over an earlier traced run's directory, running nothing.
    if (oracle3Only)
    {
        size_t compiles, opened, lookups;
        const failures = manifestCompleteness(p.graph, root, into, compiles, opened, lookups);
        foreach (f; failures[0 .. failures.length < 40 ? $ : 40])
            writeln("oracle 3: ", f);
        writeln(failures.length ? "fail" : "pass", " oracle 3 (manifest completeness): ", compiles, " compiles, ",
            opened, " files opened, ", lookups, " failed lookups under their roots; ", failures.length, " failures");
        return failures.length ? 1 : 0;
    }
    // Oracle 3: every compile under `strace`, its trace beside its manifest.
    if (traceCompiles)
    {
        const strace = onPath("strace");
        if (strace is null)
        {
            stderr.writeln("plan-graph: --trace-compiles needs strace on PATH");
            return 2;
        }
        foreach (ref a; p.graph.actions)
            if (a.kind == ActionKind.compile)
                a.action.match!(
                    (ref ProcessAction pa) {
                        pa.argv = [strace, "-f", "-y", "-qq", "-e", "trace=%file", "-o", "$MEASURE/trace", "--"]
                            ~ pa.argv;
                    },
                    (ref _) {});
    }
    // D39's spike: every build action confined to its own directories and
    // without a network; tests too with `--confine-tests`, which may also
    // write their temporary directory.
    if (confine != Confinement.none)
    {
        import std.process : execute;

        const wrapper = buildPath(into, "confine");
        const built = execute([tools.compiler, "-O", "-of=" ~ wrapper, buildPath(root, "apps/ci/tools/confine.d")]);
        if (built.status != 0)
        {
            stderr.writeln("plan-graph: cannot build the confinement wrapper: ", built.output);
            return 2;
        }
        foreach (ref a; p.graph.actions)
        {
            if (a.kind == ActionKind.test && confine != Confinement.tests)
                continue;
            // The dub trap below records its calls beside itself, so a
            // confined action that runs dub is still seen (BGX1).
            string[] prefix = [wrapper, "--write=$OUT", "--write=$MEASURE", "--no-network",
                "--write=" ~ buildPath(into, "dub-trap")];
            if (a.kind == ActionKind.test)
                prefix ~= "--write=" ~ environment.get("TMPDIR", "/tmp");
            prefix ~= "--";
            a.action.match!(
                (ref ProcessAction pa) { pa.argv = prefix ~ pa.argv; },
                (ref _) {});
        }
    }
    // Generators and tests run with the environment they are given here,
    // declared whole (BGX1): the driver's own.
    // Oracle 11 step 1 (BGX1): a `dub` first on their `PATH` that records
    // each call and fails, so a test that runs dub is seen.
    import std.file : exists, readText;

    const trap = buildPath(into, "dub-trap");
    const declared = declaredEnvironment(trap);
    const layout = RunLayout(root, into, cache, toolchain.identity, checkDeterminism);
    auto nodes = executionNodes(p.graph, layout, declared);
    auto w = stdout.lockingTextWriter;
    import sparkles.build_graph.execute : RunStats;

    RunStats stats;
    const r = runActions(nodes, p.graph, layout, w, runJobs ? runJobs : cast(uint) totalCPUs, &stats);
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
    if (traceCompiles)
    {
        size_t compiles, opened, lookups;
        const failures = manifestCompleteness(p.graph, root, into, compiles, opened, lookups);
        foreach (f; failures[0 .. failures.length < 40 ? $ : 40])
            writeln("oracle 3: ", f);
        writeln(failures.length ? "fail" : "pass", " oracle 3 (manifest completeness): ", compiles, " compiles, ",
            opened, " files opened, ", lookups, " failed lookups under their roots; ", failures.length, " failures");
        if (failures.length)
            return 1;
    }
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


/**
BGS7's operations on the store beneath `cache`, the test-only driver's
`ci cache store`: `size`, `list`, `gc`, `verify`, `evict[=<results bytes>]`,
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

    tools = Tools(compiler: onPath("ldc2"), archiver: onPath("ar"), cc: onPath("cc"), linker: onPath("ld.lld"),
        fail: onPath("false"), deviceCompiler: onPath("ldc2-vulkan"));
    foreach (name; ["spirv-val", "spirv-opt", "spirv-dis", "spirv-as", "spirv-cross", "glslangValidator"])
        tools.shaderTools ~= [name, onPath(name)];
    if (tools.compiler is null || tools.archiver is null || tools.cc is null || tools.linker is null)
        return "ldc2, ar, cc and ld.lld must be on PATH";
    // The fork's dependency output, which a compile's manifest comes from.
    const help = execute([tools.compiler, "--help-hidden"]);
    tools.dependencyOutput = help.output.canFind("makedeps-digests") && !noDependencyOutput;
    toolchain = toolchainOf(tools);
    tools.config = toolchain.config;
    if (testTimeout != Duration.max)
        tools.testLimit = testTimeout;
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
`ci cache store explain <task>` (BGS8): plans the repository's test
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
    import std.parallelism : totalCPUs;
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
    cast(void) runActions(nodes, sub, layout, quiet, cast(uint) totalCPUs, &stats);

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
