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
lint, `sparkles:unittest-layout`) and lowers them to actions. Without
`--check` it prints the graph: one block per action, sorted by id, then the
edges. With `--check` it verifies E2's gate instead and prints a verdict per
oracle:

$(LIST
    * the graph is deterministic: two plans print the same bytes (oracle 14);
    * one compile per variant (BGA2);
    * the layout lint's scenarios fail planning by place, and pass inside
      `unittest` blocks (oracle 8's planning scenarios);
    * every read outside a package directory is one of `ci`'s workspace
      inputs (oracle 20 step 3, CIC5);
    * no planning module touches the file system but through the VFS, and a
      fixture plans the same in memory and on disk (oracle 24 steps 1 and 3).
)

Needs the dev shell's `SPARKLES_DUB_SOURCES` for the registry packages.
*/
module plan_graph;

import std.algorithm : canFind, endsWith, filter, map, sort, startsWith;
import std.array : array, join;
import std.conv : text;
import std.file : dirEntries, readText, SpanMode;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.sumtype : match;

import sparkles.build_graph.actions : ActionGraph, ActionKind, planActions, taskNodes;
import sparkles.build_graph.variants : LayoutCheck, PlanOptions, Role, ToolchainIdentity,
    VariantPlan, planVariants;
import sparkles.build_primitives.resolve.configure : Resolution, ResolveRequest, resolve;
import sparkles.build_primitives.resolve.platform : BuildPlatform;
import sparkles.build_primitives.resolve.project : RegistrySources;
import sparkles.build_primitives.resolve.registry : nixRegistrySources, readDubLocks;
import sparkles.build_primitives.resolve.tree : ResolveTree, memoryTree, systemTree;
import sparkles.build_primitives.task.action : InProcessAction, InertAction, ProcessAction;
import sparkles.build_primitives.workspace.discovery : ReadSet, readWorkspaceAt;
import sparkles.build_primitives.workspace.package_graph : PackageGraph, RecipeRole, buildPackageGraph;
import sparkles.unittest_layout.lint : checkLayout;

enum host = ["linux", "posix"];

int main(string[] args)
{
    const check = args.canFind("--check");
    const showReads = args.canFind("--reads");
    const positional = args[1 .. $].filter!(a => !a.startsWith("--")).array;
    const root = buildNormalizedPath(absolutePath(positional.length ? positional[0] : "."));

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
                writeln("read ", e.kind, " ", e.path, e.found ? "" : " (absent)");
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

    // Oracle 20 step 3 (CIC5): reads outside package directories are
    // workspace inputs.
    const cic5 = checkCic5(root, first);
    verdict("oracle 20 step 3 (CIC5)", cic5.length == 0,
        cic5.length ? cic5 : text(first.reads.entries.length, " reads, each inside a package or a workspace input"));

    // Oracle 24 steps 1 and 3.
    const audit = sourceAudit(root);
    verdict("oracle 24 step 1 (source audit)", audit.length == 0, audit.length ? audit : "planning modules use the VFS only");
    const backends = backendsAgree();
    verdict("oracle 24 step 3 (memory and disk agree)", backends.length == 0,
        backends.length ? backends : "a fixture plans the same in memory and on disk");

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

Planned planRepository(string root)
{
    Planned p;
    const sources = environment.get("SPARKLES_DUB_SOURCES");
    if (sources is null)
        return Planned("SPARKLES_DUB_SOURCES is not set; run in the dev shell");
    auto tree = systemTree();
    const read = readWorkspaceAt(root);
    if (read.hasError)
        return Planned(text(read.error));
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")], tree);
    if (locked.hasError)
        return Planned(locked.error);
    const registry = nixRegistrySources(locked.value, sources, tree);
    if (registry.hasError)
        return Planned(registry.error);
    const graph = buildPackageGraph(read.value.rootName, read.value.recipes, RecipeRole.test, host);
    if (graph.hasError)
        return Planned(text(graph.error));

    Resolution[] rs;
    string failure;
    VariantPlan plan;
    p.reads = tree.recorded(() @safe {
        foreach (ref pkg; graph.value.packages)
        {
            auto request = ResolveRequest(directory: root, subPackage: pkg.shortName, buildType: "unittest",
                platform: BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2113, "1.43.0"), testRoot: true);
            foreach (n, s; registry.value)
                request.registry[n] = s;
            auto r = resolve(request, tree);
            if (r.hasError)
            {
                failure = text(pkg.shortName, ": ", r.error.message);
                return;
            }
            rs ~= r.value;
        }
        string[] registryNames = registry.value.keys;
        auto planned = planVariants(rs, PlanOptions(ToolchainIdentity("ldc", "dev-shell"), layoutLint(),
            registryNames), tree);
        if (planned.hasError)
        {
            failure = text(planned.error);
            return;
        }
        plan = planned.value;
    });
    if (failure.length)
        return Planned(failure);
    p.plan = plan;
    p.requests = rs.length;
    foreach (ref r; rs)
        p.targets += r.targets.length;
    foreach (ref r; rs)
        foreach (ref t; r.targets)
            if (!p.packageDirectories.canFind(t.directory))
                p.packageDirectories ~= t.directory;

    auto g = planActions(p.plan, rs, root);
    if (g.hasError)
        return Planned(text(g.error));
    p.graph = g.value;
    p.text = render(p.graph, root);
    return p;
}

// The graph as text: actions sorted by id, then edges.
string render(ref const ActionGraph g, string root) @safe
{
    string[] blocks;
    foreach (ref a; g.actions)
    {
        string b = text(a.id.text, "  weight=", a.weight, "\n");
        b ~= a.action.match!(
            (ref const ProcessAction p) => text("  run ", p.argv.join(" "), p.cwd.length ? "  (in " ~ p.cwd ~ ")" : "", "\n"),
            (ref const InProcessAction i) => text("  in-process ", i.handler, " ", i.arguments.length, " arguments\n"),
            (ref const InertAction x) => text("  inert ", x.note, "\n"));
        foreach (o; a.outputs)
            b ~= text("  out $OUT/", o.path, o.tree ? "/**" : "", "\n");
        blocks ~= b;
    }
    blocks.sort;
    string[] edges = g.edges.map!(e => text(e.prerequisite.text, " -> ", e.dependent.text)).array;
    edges.sort;
    return blocks.join("") ~ "edges\n" ~ edges.map!(e => "  " ~ e ~ "\n").join("");
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

auto planFixture(ResolveTree tree)
{
    auto r = resolve(ResolveRequest(directory: "/r", subPackage: ":t1", buildType: "unittest",
        platform: BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2113, "1.43.0"), testRoot: true), tree);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    return planVariants([r.value], PlanOptions(ToolchainIdentity("ldc", "fixture"), layoutLint()), tree);
}

// CIC5: every read outside a package directory is a workspace input.
string checkCic5(string root, ref const Planned p)
{
    import repository_inputs : repositoryFocus;
    import sparkles.build_primitives.workspace.select : workspaceInputSets;

    auto tree = systemTree();
    const sources = environment.get("SPARKLES_DUB_SOURCES");
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")], tree);
    auto registry = nixRegistrySources(locked.value, sources, tree);
    const workspace = readWorkspaceAt(root).value;
    const graph = buildPackageGraph(workspace.rootName, workspace.recipes, RecipeRole.test, host).value;
    const options = repositoryFocus(BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2113, "1.43.0"),
        registry.value);
    auto inputs = workspaceInputSets(root, tree, graph, workspace, options, host);

    string failures;
    size_t outside;
    foreach (e; p.reads.entries)
    {
        if (!e.path.startsWith(root ~ "/"))
            continue; // the registry's store paths: immutable, keyed by the lockfiles
        if (p.packageDirectories.canFind!(d => e.path.startsWith(d ~ "/") || e.path == d))
            continue;
        ++outside;
        const rel = e.path[root.length + 1 .. $];
        if (!inputs.inWorkspace(rel))
            failures ~= " " ~ rel;
    }
    return failures.length ? "not workspace inputs:" ~ failures : null;
}

// Oracle 24 step 1: outside `unittest` blocks, no planning module imports
// `std.file` or names `std.stdio`'s `File`.
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
                if (importsFile || namesFile)
                    failures ~= text(" ", e.name[root.length + 1 .. $], ":", t.line);
            }
        }
    return failures.length ? "reaches the file system directly:" ~ failures : null;
}

// Oracle 24 step 3, for the memory and blocking backends: a fixture planned
// in memory and written to disk plans to the same graph and reads.
string backendsAgree()
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : dirName;
    import std.process : thisProcessID;

    string[string] files = [
        "dub.sdl": "name \"r\"\nsubPackage \"t1\"\nsubPackage \"leaf\"\n",
        "t1/dub.sdl": "name \"t1\"\ndependency \"r:leaf\" path=\"..\"\n"
            ~ "configuration \"library\" {\n}\nconfiguration \"unittest\" {\n    versions \"T1Only\"\n}\n",
        "t1/source/t1.d": "module t1;\n",
        "leaf/dub.sdl": "name \"leaf\"\n",
        "leaf/source/leaf.d": "module leaf;\nversion (T1Only) int x;\n",
    ];
    const disk = buildPath(tempDir, text("plan-graph-", thisProcessID));
    scope (exit)
        rmdirRecurse(disk);
    string[string] inMemory;
    foreach (path, content; files)
    {
        inMemory["/r/" ~ path] = content;
        mkdirRecurse(buildPath(disk, path).dirName);
        write(buildPath(disk, path), content);
    }
    string planOn(ResolveTree tree, string at)
    {
        ReadSet reads;
        string out_;
        reads = tree.recorded(() @safe {
            auto r = resolve(ResolveRequest(directory: at, subPackage: ":t1", buildType: "unittest",
                platform: BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2113, "1.43.0"), testRoot: true), tree);
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
    const b = planOn(systemTree(), disk);
    return a == b ? null : "the plans differ:\n" ~ a ~ "---\n" ~ b;
}
