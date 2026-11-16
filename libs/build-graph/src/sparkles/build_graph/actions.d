/**
The action graph: the tool invocations that build and test planned variants
(build-graph SPEC BGA1–BGA3, BGA8), without running them.

$(LREF planActions) lowers a $(LREF VariantPlan):

$(LIST
    * one `compile` per variant, over all its own modules in one compiler
        invocation (BGA2); a test root's compile also takes its generated
        test-root module;
        * one `archive` per dependency library, of its compile's object;
        * one `link` per request whose root is a test root or an application,
        of the root's object and the archives it links, in link order;
        * one `test` per test root's link;
        * a `generate` before a compile that needs one: the test-root module,
        and a dub pre-generate command, which is not yet a typed generator
        (§7, E3).
)

A compile reads its dependencies' sources through import paths and waits for
no archive; a link waits for the archives it links (BGA2). Every edge is an
`onSuccess` task edge.

An action's argument vector names paths with placeholders, as its key will
(BGA6): `$ROOT` for the repository root, `$OUT` for the action's private
output directory, `$MEASURE` for its measurement directory, and `$IN(<id>)`
for the output directory of the action `<id>`. In-tree paths are relative to
the root, as the compile runs there (BGA5). Every action declares its outputs
relative to `$OUT` (BGA3).

$(LREF taskNodes) exposes the actions as task nodes for the task-DAG
executor (BGA8): ids of the form `<kind>:<package>:<role>:<vendor>:<d>`
(observability OBD2), the default weights, and the test runner's and the
linker's thread counts set from them.
*/
module sparkles.build_graph.actions;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : array, join;
import std.conv : text;

import sparkles.build_graph.variants : Role, Variant, VariantPlan;
import sparkles.build_primitives.resolve.configure : Resolution;
import sparkles.build_primitives.resolve.settings : BuildOption, BuildSettings, TargetType;
import sparkles.build_primitives.task.action : InProcessAction, ProcessAction, SandboxPolicy, TaskAction;
import std.sumtype : match;
import sparkles.build_primitives.task.model : EdgeCondition, EdgeReason, PlanExpected, PresentationKey,
    ResourceClaim, TaskEdge, TaskId, TaskKind, TaskNode, planErr, planOk, qualifiedNameSegment, taskId;

/// The kinds of action (BGA1); a kind outside these is an error.
enum ActionKind : ubyte
{
    compile,  /// one compiler invocation over a variant's own modules
    archive,  /// a static library from a compile's output
    link,     /// an executable from objects and archives
    generate, /// a generator (§7)
    test,     /// a test run (§9)
}

/// An action's default weight, as BGA8 states it.
uint defaultWeight(ActionKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case ActionKind.compile: return 2;
        case ActionKind.archive: return 1;
        case ActionKind.link: return 2;
        case ActionKind.generate: return 1;
        case ActionKind.test: return 2;
    }
}

/// One output an action declares, relative to its `$OUT` (BGA3).
struct DeclaredOutput
{
    string path; ///
    bool tree;   /// a directory tree, as a generator whose names vary declares
}

/// One action.
struct Action
{
    ActionKind kind; ///
    TaskId id;       ///
    size_t variant;  /// the variant it builds or tests
    /// What it runs: a process, or an in-process generator.
    TaskAction action;
    DeclaredOutput[] outputs; ///
    uint weight;              /// its claim (BGA8)
}

/// The actions and their edges.
struct ActionGraph
{
    Action[] actions; /// in the order planned
    TaskEdge[] edges; /// every one `onSuccess`

    /// The action with id `id`, or null.
    inout(Action)* find(TaskId id) inout @safe pure nothrow @nogc
    {
        foreach (ref a; actions)
            if (a.id == id)
                return &a;
        return null;
    }
}

/// The tools an action graph names.
struct Tools
{
    string compiler = "ldc2"; /// by absolute path in a real plan (BGA4)
    string archiver = "llvm-ar"; ///
}

/// Why the graph could not be made.
struct ActionError
{
    string message; ///

    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;

        put(w, message);
    }
}

/**
Lowers `plan`, over the `resolutions` it was planned from, to actions.

Params:
    plan = the variants
    resolutions = the requests, in the plan's order
    root = the repository root, which in-tree paths are made relative to
    tools = the compiler and the archiver
*/
PlanExpected!(ActionGraph, ActionError) planActions(ref const VariantPlan plan,
    const Resolution[] resolutions, string root, const Tools tools = Tools.init) @safe
{
    ActionGraph g;
    bool[string] made;
    // Each variant's compile, by variant.
    TaskId[size_t] compileOf;
    TaskId[size_t] archiveOf;

    TaskId add(Action a)
    {
        if (a.id.text in made)
            return a.id;
        made[a.id.text] = true;
        g.actions ~= a;
        return a.id;
    }

    void edge(TaskId from, TaskId to)
    {
        foreach (e; g.edges)
            if (e.prerequisite == from && e.dependent == to)
                return;
        g.edges ~= TaskEdge(from, to, EdgeCondition.onSuccess, EdgeReason.packageDependency);
    }

    foreach (ri, ref r; resolutions)
    {
        if (ri >= plan.requests.length)
            return planErr!ActionGraph(ActionError("a resolution the plan does not cover"));
        const targets = plan.requests[ri];
        foreach (ti, vi; targets)
        {
            const v = &plan.variants[vi];
            if (vi in compileOf)
                continue;
            TaskId[] before;
            // A test root's entry point is a generated module (§7).
            if (v.role == Role.testRoot && r.testRoot.generated)
            {
                auto gen = Action(ActionKind.generate, actionId(ActionKind.generate, *v), vi,
                    TaskAction(InProcessAction("generate:test-root-module",
                        r.testRoot.testedSources.dup)),
                    [DeclaredOutput("dub_test_root.d")], defaultWeight(ActionKind.generate));
                before ~= add(gen);
            }
            foreach (n, cmd; v.settings.preGenerateCommands)
            {
                auto gen = Action(ActionKind.generate,
                    actionId(ActionKind.generate, *v, n + (v.role == Role.testRoot ? 1 : 0)), vi,
                    TaskAction(ProcessAction(argv: ["sh", "-c", cmd], cwd: relative(v.directory, root))),
                    [DeclaredOutput(".", true)], defaultWeight(ActionKind.generate));
                before ~= add(gen);
            }
            const generatedRoot = before.length && v.role == Role.testRoot && r.testRoot.generated
                ? before[0] : TaskId.init;
            auto c = Action(ActionKind.compile, actionId(ActionKind.compile, *v), vi,
                TaskAction(ProcessAction(argv: compileArgv(*v, root, tools, generatedRoot),
                    sandbox: SandboxPolicy.taskDirectory)),
                [DeclaredOutput(objectName(*v))], defaultWeight(ActionKind.compile));
            compileOf[vi] = add(c);
            foreach (b; before)
                edge(b, compileOf[vi]);

            if (v.role == Role.dependencyLibrary && v.settings.targetType != TargetType.none)
            {
                auto a = Action(ActionKind.archive, actionId(ActionKind.archive, *v), vi,
                    TaskAction(ProcessAction(argv: [tools.archiver, "rcsD", "$OUT/" ~ archiveName(*v),
                        inputPath(compileOf[vi], objectName(*v))], sandbox: SandboxPolicy.taskDirectory)),
                    [DeclaredOutput(archiveName(*v))], defaultWeight(ActionKind.archive));
                archiveOf[vi] = add(a);
                edge(compileOf[vi], archiveOf[vi]);
            }
        }

        // The binary: the root's object and the archives it links.
        const rootVariant = targets.length ? targets[0] : size_t.max;
        if (rootVariant == size_t.max)
            continue;
        const v = &plan.variants[rootVariant];
        if (v.role == Role.dependencyLibrary)
            continue;
        string[] archives;
        TaskId[] archiveIds;
        foreach (name; r.targets[0].linkDependencies)
            foreach (ti, ref t; r.targets)
                if (t.package_ == name)
                    if (auto a = targets[ti] in archiveOf)
                    {
                        archives ~= inputPath(*a, archiveName(plan.variants[targets[ti]]));
                        archiveIds ~= *a;
                    }
        const weight = defaultWeight(ActionKind.link);
        auto l = Action(ActionKind.link, actionId(ActionKind.link, *v), rootVariant,
            TaskAction(ProcessAction(argv: linkArgv(*v, root, tools, compileOf[rootVariant], archives, weight),
                sandbox: SandboxPolicy.taskDirectory)),
            [DeclaredOutput(binaryName(*v))], weight);
        const linkId = add(l);
        edge(compileOf[rootVariant], linkId);
        foreach (a; archiveIds)
            edge(a, linkId);

        if (v.role == Role.testRoot)
        {
            const testWeight = defaultWeight(ActionKind.test);
            auto t = Action(ActionKind.test, actionId(ActionKind.test, *v), rootVariant,
                TaskAction(ProcessAction(argv: [inputPath(linkId, binaryName(*v)), "-t", text(testWeight)],
                    cwd: relative(v.directory, root), sandbox: SandboxPolicy.taskDirectory)),
                null, testWeight);
            edge(linkId, add(t));
        }
    }
    return planOk!ActionError(g);
}

/**
The actions as task nodes for the task-DAG executor (BGA8), with their
edges: `compile`, `archive`, `link` and `generate` are `build` work, `test`
is `test` work, each with the claim BGA8 gives its kind.
*/
TaskNode[] taskNodes(ref const ActionGraph g) @safe
{
    import sparkles.build_primitives.task.model : FailurePolicy, OutputPolicy;

    TaskNode[] nodes;
    foreach (ref a; g.actions)
    {
        nodes ~= TaskNode(
            id: a.id,
            kind: a.kind == ActionKind.test ? TaskKind.test : TaskKind.build,
            label: a.id.text,
            order: PresentationKey(1, a.id.text, a.kind, 0),
            resources: ResourceClaim(jobsWeight: a.weight),
            action: copyOf(a.action),
            failurePolicy: FailurePolicy.authoritative,
            outputPolicy: OutputPolicy.replay);
    }
    return nodes;
}

/// The id of `v`'s action of `kind` (OBD2): `<kind>:<package>:<role>:<vendor>:<d>`,
/// with `<d>` the first twelve hexadecimal digits of the variant key with its
/// toolchain identity replaced by the vendor. A second `generate` of one
/// variant takes its ordinal as one more segment.
TaskId actionId(ActionKind kind, ref const Variant v, size_t ordinal = 0) @safe
{
    import std.digest.sha : sha256Of;
    import std.array : replace;

    const vendorKey = v.keyText.replace("toolchain=" ~ v.toolchain.vendor ~ ":" ~ v.toolchain.identity,
        "toolchain=" ~ v.toolchain.vendor);
    const d = hexOf(sha256Of(vendorKey))[0 .. 12];
    const role = v.role == Role.testRoot ? "test-root" : v.role == Role.application ? "application" : "library";
    auto id = ordinal
        ? taskId(text(kind), qualifiedNameSegment(v.package_), role, v.toolchain.vendor, d, text(ordinal))
        : taskId(text(kind), qualifiedNameSegment(v.package_), role, v.toolchain.vendor, d);
    assert(id.hasValue);
    return id.value;
}

private:

// A copy of `a` that shares no array with it.
TaskAction copyOf(ref const TaskAction a) @safe pure nothrow
{
    import sparkles.build_primitives.task.action : EnvEntry, InertAction;

    return a.match!(
        (ref const ProcessAction p) => TaskAction(ProcessAction(p.argv.dup, p.envDelta.dup, p.cwd, p.stdin,
            p.timeout, p.sandbox)),
        (ref const InProcessAction i) => TaskAction(InProcessAction(i.handler, i.arguments.dup)),
        (ref const InertAction x) => TaskAction(InertAction(x.note)));
}

string hexOf(const ubyte[32] bytes) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[64] buf;
    foreach (i, b; bytes)
    {
        buf[2 * i] = digits[b >> 4];
        buf[2 * i + 1] = digits[b & 0xF];
    }
    return buf[].idup;
}

string baseName(ref const Variant v) @safe pure nothrow
{
    import std.array : replace;

    return v.settings.targetName.length ? v.settings.targetName : v.package_.replace(":", "_");
}

string objectName(ref const Variant v) @safe pure nothrow => baseName(v) ~ ".o";
string archiveName(ref const Variant v) @safe pure nothrow => "lib" ~ baseName(v) ~ ".a";
string binaryName(ref const Variant v) @safe pure nothrow => baseName(v);

string inputPath(TaskId producer, string path) @safe pure nothrow => "$IN(" ~ producer.text ~ ")/" ~ path;

// `path` relative to the root when it is under it, as BGA5 passes it.
string relative(string path, string root) @safe pure nothrow
{
    if (path == root)
        return ".";
    if (path.startsWith(root ~ "/"))
        return path[root.length + 1 .. $];
    return path;
}

// The compiler's arguments for a variant's one compile.
string[] compileArgv(ref const Variant v, string root, const Tools tools, TaskId generatedRoot) @safe
{
    const s = &v.settings;
    const ldc = v.platform.compiler == "ldc";
    string[] argv = [tools.compiler, "-c"];
    if (ldc)
        argv ~= "-singleobj";
    argv ~= "-of=$OUT/" ~ objectName(v);
    argv ~= optionFlags(s.options, ldc);
    foreach (f; s.dflags)
        argv ~= f;
    foreach (p; s.importPaths)
        argv ~= "-I=" ~ relative(p, root);
    foreach (p; s.stringImportPaths)
        argv ~= "-J=" ~ relative(p, root);
    foreach (id; s.versions)
        argv ~= (ldc ? "-d-version=" : "-version=") ~ id;
    foreach (id; s.debugVersions)
        argv ~= (ldc ? "-d-debug=" : "-debug=") ~ id;
    foreach (f; s.sourceFiles)
        if (!isLinkerInput(f))
            argv ~= relative(f, root);
    if (!generatedRoot.empty)
        argv ~= inputPath(generatedRoot, "dub_test_root.d");
    return argv;
}

// The link's arguments: the root's object, the archives in link order, the
// libraries and linker flags, and the linker's thread count (BGA8).
string[] linkArgv(ref const Variant v, string root, const Tools tools, TaskId compile,
    const string[] archives, uint threads) @safe
{
    const s = &v.settings;
    string[] argv = [tools.compiler, "-of=$OUT/" ~ binaryName(v), inputPath(compile, objectName(v))];
    argv ~= archives;
    foreach (f; s.sourceFiles)
        if (isLinkerInput(f))
            argv ~= relative(f, root);
    foreach (f; s.linkerFiles)
        argv ~= relative(f, root);
    foreach (lib; s.libs)
        argv ~= "-L-l" ~ lib;
    foreach (f; s.lflags)
        argv ~= "-L" ~ f;
    argv ~= "-L--threads=" ~ text(threads);
    return argv;
}

bool isLinkerInput(string f) @safe pure nothrow @nogc
    => f.endsWith(".a") || f.endsWith(".o") || f.endsWith(".so") || f.endsWith(".lib") || f.endsWith(".obj");

// dub's translation of build options to compiler flags, for LDC and DMD.
string[] optionFlags(uint options, bool ldc) @safe pure nothrow
{
    alias O = BuildOption;
    string[] flags;
    void on(O o, string ldcFlag, string dmdFlag)
    {
        if (options & o)
            flags ~= ldc ? ldcFlag : dmdFlag;
    }
    on(O.debugMode, "-d-debug", "-debug");
    on(O.releaseMode, "-release", "-release");
    on(O.coverage, "-cov", "-cov");
    on(O.coverageCTFE, "-cov=ctfe", "-cov=ctfe");
    on(O.debugInfo, "-g", "-g");
    on(O.debugInfoC, "-gc", "-gc");
    on(O.alwaysStackFrame, "-disable-fp-elim", "-gs");
    on(O.inline, "-enable-inlining", "-inline");
    on(O.noBoundsCheck, "-boundscheck=off", "-boundscheck=off");
    on(O.optimize, "-O3", "-O");
    on(O.profile, "-fdmd-trace-functions", "-profile");
    on(O.profileGC, "-profile=gc", "-profile=gc");
    on(O.unittests, "-unittest", "-unittest");
    on(O.verbose, "-v", "-v");
    on(O.syntaxOnly, "-o-", "-o-");
    on(O.warnings, "-wi", "-wi");
    on(O.warningsAsErrors, "-w", "-w");
    on(O.ignoreDeprecations, "-d", "-d");
    on(O.deprecationWarnings, "-dw", "-dw");
    on(O.deprecationErrors, "-de", "-de");
    on(O.property, "-property", "-property");
    on(O.pic, "-relocation-model=pic", "-fPIC");
    on(O.betterC, "-betterC", "-betterC");
    on(O.lowmem, "-lowmem", "-lowmem");
    on(O.color, "-enable-color", "-color");
    return flags;
}

version (unittest)
{
    import sparkles.build_graph.variants : PlanOptions, ToolchainIdentity, planVariants;
    import sparkles.build_primitives.resolve.configure : ResolveRequest, resolve;
    import sparkles.build_primitives.resolve.platform : BuildPlatform;
    import sparkles.build_primitives.resolve.tree : memoryTree;

    // Two test roots on `mid`, which uses `leaf`: as the variants' tests.
    private ActionGraph graphOf(string[] packages...) @safe
    {
        auto tree = memoryTree([
            "/r/dub.sdl": "name \"r\"\nsubPackage \"t1\"\nsubPackage \"t2\"\nsubPackage \"mid\"\nsubPackage \"leaf\"\n",
            "/r/t1/dub.sdl": "name \"t1\"\ndependency \"r:mid\" path=\"..\"\n"
                ~ "configuration \"library\" {\n}\nconfiguration \"unittest\" {\n    versions \"T1Only\"\n}\n",
            "/r/t1/source/t1.d": "module t1;\n",
            "/r/t2/dub.sdl": "name \"t2\"\ndependency \"r:mid\" path=\"..\"\n"
                ~ "configuration \"library\" {\n}\nconfiguration \"unittest\" {\n}\n",
            "/r/t2/source/t2.d": "module t2;\n",
            "/r/mid/dub.sdl": "name \"mid\"\ndependency \"r:leaf\" path=\"..\"\n",
            "/r/mid/source/mid.d": "module mid;\n",
            "/r/leaf/dub.sdl": "name \"leaf\"\n",
            "/r/leaf/source/leaf.d": "module leaf;\n",
        ]);
        Resolution[] rs;
        foreach (p; packages)
        {
            auto r = resolve(ResolveRequest(directory: "/r", subPackage: p, buildType: "unittest",
                platform: BuildPlatform(["linux", "posix"], ["x86_64"], "ldc", "ldc2", 2111, "1.41.0"),
                testRoot: true), tree);
            assert(r.hasValue, r.hasError ? r.error.message : null);
            rs ~= r.value;
        }
        const plan = planVariants(rs, PlanOptions(ToolchainIdentity("ldc", "toolchain-1")), tree);
        assert(plan.hasValue);
        auto g = planActions(plan.value, rs, "/r");
        assert(g.hasValue);
        return g.value;
    }

    private size_t count(ref const ActionGraph g, ActionKind kind) @safe
    {
        size_t n;
        foreach (ref a; g.actions)
            n += a.kind == kind;
        return n;
    }
}

///
@("build_graph.actions.planActions.oneCompilePerVariant")
@safe unittest
{
    const g = graphOf(":t1", ":t2");
    // Two test roots, one `mid` and one `leaf` (neither mentions a root's
    // version): four compiles, two archives, two links, two tests, and the
    // two test-root modules.
    assert(count(g, ActionKind.compile) == 4);
    assert(count(g, ActionKind.archive) == 2);
    assert(count(g, ActionKind.link) == 2);
    assert(count(g, ActionKind.test) == 2);
    assert(count(g, ActionKind.generate) == 2);

    // A compile waits for no archive (BGA2): only generators precede one.
    foreach (ref e; g.edges)
    {
        const to = g.find(e.dependent), from = g.find(e.prerequisite);
        assert(e.condition == EdgeCondition.onSuccess);
        if (to.kind == ActionKind.compile)
            assert(from.kind == ActionKind.generate);
    }
}

@("build_graph.actions.taskNodes.oracle14")
@safe unittest
{
    import sparkles.build_primitives.task.graph : TaskGraphBuilder;

    // Oracle 14: the same request planned twice has the same ids, claims
    // and edges.
    const a = graphOf(":t1"), b = graphOf(":t1");
    assert(a.actions.length == b.actions.length);
    foreach (i; 0 .. a.actions.length)
    {
        assert(a.actions[i].id == b.actions[i].id && a.actions[i].weight == b.actions[i].weight);
        assert(a.actions[i].action == b.actions[i].action);
    }
    assert(a.edges == b.edges);

    // The ids take OBD2's form, and the toolchain identity is not in them.
    const compile = a.actions[1];
    assert(compile.kind == ActionKind.compile && compile.id.text.startsWith("compile:r.t1:test-root:ldc:"),
        compile.id.text);

    // A link carries its claimed thread count, and so does a test run.
    foreach (ref act; a.actions)
    {
        const argv = act.action.match!((ref const ProcessAction p) => p.argv.dup, (_) => string[].init);
        if (act.kind == ActionKind.link)
            assert(argv.canFind("-L--threads=2"));
        if (act.kind == ActionKind.test)
            assert(argv[$ - 2 .. $] == ["-t", "2"]);
    }

    // The executor accepts the nodes: no cycle, no unknown endpoint.
    TaskGraphBuilder builder;
    foreach (n; taskNodes(a))
        builder.add(n);
    foreach (e; a.edges)
        builder.add(e);
    const built = builder.build();
    assert(built.hasValue, built.hasError ? text(built.error) : null);
}

@("build_graph.actions.planActions.toolchainBumpKeepsIds")
@safe unittest
{
    // OBD2: a toolchain bump changes every variant key, but no task id.
    import sparkles.build_graph.variants : Variant;

    Variant v;
    v.package_ = "r:leaf";
    v.toolchain = ToolchainIdentity("ldc", "one");
    const before = actionId(ActionKind.compile, v);
    v.toolchain = ToolchainIdentity("ldc", "two");
    assert(actionId(ActionKind.compile, v) == before);
    v.toolchain = ToolchainIdentity("dmd", "two");
    assert(actionId(ActionKind.compile, v) != before);
}
