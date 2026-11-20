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
        * a `generate` before a compile that needs one: the test-root module, in
        process, and a recognized pre-generate command (§7), whose tool is
        built first and whose output the compile reads in place of the
        string import root it fills. The shader compiler runs in its direct
        invocation, its device configuration written for it (BGG3).
)

A compile reads its dependencies' sources through import paths and waits for
no archive; a link waits for the archives it links (BGA2). Every edge is an
`onSuccess` task edge, but a coverage attempt's fallback (CIC7): the coverage
build's actions are provisional, and the plain compile waits for the coverage
link's failure on an `onFailure` edge. The plain compile's key is its
variant's, whichever graph holds it (invariant 7).

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

import core.time : Duration, minutes;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : array, join;
import std.conv : text;

import sparkles.build_graph.variants : Role, Variant, VariantPlan;
import sparkles.build_graph.generators : GeneratorKind;
import sparkles.build_primitives.resolve.configure : Resolution;
import sparkles.build_primitives.resolve.settings : BuildOption, BuildSettings, TargetType;
import sparkles.build_primitives.task.action : EnvEntry, InProcessAction, ProcessAction, SandboxPolicy,
    TaskAction;
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
    /// Part of a coverage build: its failure is classified by the plain
    /// retry behind it, so it never fails the run (CIC7, TDC4).
    bool provisional;
    /// BGK9: the `pkg-config` search behind the flags it uses, as
    /// `pkgConfigSearch` writes it: each file used and each candidate absent
    /// before it, which its declared key covers when the action runs.
    string[] searchInputs;
}

/// The actions and their edges.
struct ActionGraph
{
    Action[] actions; /// in the order planned
    /// `onSuccess`, but for a coverage fallback's `onFailure` edges
    TaskEdge[] edges;

    /// The action with id `id`, or null.
    inout(Action)* find(TaskId id) inout @safe pure nothrow @nogc
    {
        foreach (ref a; actions)
            if (a.id == id)
                return &a;
        return null;
    }
}

/**
One leg of a package's tests (ci task-DAG CIC11, CIC14): one test action
that runs the binary with `-t threads`, claiming that weight. A named leg's
action id carries its name as a last segment; the unnamed one's is the
test root's own.
*/
struct TestLeg
{
    uint threads = defaultWeight(ActionKind.test); ///
    /// `--skip-slow`: the `@slow` tests are left to a run of their own.
    bool skipSlow;
    string name; /// the id's last segment; empty for none
}

/// The tools an action graph names.
struct Tools
{
    string compiler = "ldc2"; /// by absolute path in a real plan (BGA4)
    string archiver = "llvm-ar"; ///
    /// The C compiler driver and the linker, by absolute path (BGA4): LDC
    /// takes them as `-gcc=` and `--linker=`, and searches no `PATH` for
    /// them. Empty leaves the compiler's choice.
    string cc;
    string linker; /// ditto
    /// A program that exits non-zero, by absolute path: what a generator
    /// finds under each of `failingTools` on its `PATH` (§7). Empty gives
    /// generators an empty `PATH`.
    string fail;
    /// The shader compiler's device compiler (`ldc2-vulkan`) and the SPIR-V
    /// and GLSL tools it runs, by name and absolute path (BGG3).
    string deviceCompiler;
    string[2][] shaderTools; /// ditto
    /// Whether the compiler writes the LDC fork's dependency output: the
    /// files it read with their digests and the absent candidates (BGK2),
    /// which a compile's manifest comes from.
    bool dependencyOutput;
    /// The compiler's configuration file, passed explicitly (`-conf=`, BGT1);
    /// empty leaves the compiler to find its own.
    string config;
    /// Prefix maps for the toolchain's own paths, `<path>=<fixed>` (BGA11), so
    /// no output names the store path of druntime's or Phobos' sources.
    string[] prefixMaps;
    /// How long an action may run before it is killed, failing as timed out
    /// and unpublished (BGA9, BGA12): `testLimit` for a test, `actionLimit`
    /// for every other process. `Duration.zero` sets none.
    Duration testLimit = 20.minutes;
    Duration actionLimit = 30.minutes; /// ditto
    /// The legs each test binary runs in, each its own test action.
    TestLeg[] testLegs = [TestLeg.init];
    /// Flags every compile and link takes after the recipe's, such as a
    /// sanitizer's (ci task-DAG M8); they are part of each declared key.
    string[] extraFlags;
    /// Variables every program the graph builds and runs takes: each test's
    /// and each generator's, such as the sanitizer's runtime options.
    EnvEntry[] runtimeEnvironment;
    /// Directories every link searches for libraries a recipe names by
    /// `libs` without `pkg-config`: what `$LIBRARY_PATH` gives a C driver,
    /// which a build action's empty environment (BGA4) does not. Each is a
    /// `-L-L` of the link, so its library search keys on them (BGK9).
    string[] libraryPath;
    /// Runner options a package's test legs take after the legs' own, by
    /// the package's name (`sparkles:base`): the slow tests a run selects.
    string[][string] testArguments;
}

/**
The programs a single-file generator may run but must not depend on: on its
`PATH` each is `Tools.fail`. `dmd`'s `config.d` asks `git describe` for the
compiler's version and falls back to its `VERSION` file, as it does in a
registry checkout, which has no repository (D60).
*/
immutable string[] failingTools = ["git"];

/**
A coverage attempt (CIC7): request `coverage` builds a package's test binary
with coverage, and request `plain` is the same package's plain test, its
fallback. The coverage build's actions are provisional, and the plain
compile waits on an `onFailure` edge from the coverage link.
*/
struct CoverageAttempt
{
    size_t coverage; /// the index of the coverage request
    size_t plain;    /// the index of the plain one
}

/**
A program a test runs that the graph builds (BGX2, D61): request `program`'s
binary, named to request `test`'s test action by the environment variable
`variable`. A program's own tests do not run.
*/
struct TestProgram
{
    size_t test;     /// the index of the test's request
    size_t program;  /// the index of the program's request
    string variable; /// what names the program to the test
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
    attempts = the coverage attempts among the requests
    programs = the programs the requests' tests run
*/
PlanExpected!(ActionGraph, ActionError) planActions(ref const VariantPlan plan,
    const Resolution[] resolutions, string root, const Tools tools = Tools.init,
    const CoverageAttempt[] attempts = null, const TestProgram[] programs = null) @safe
{
    ActionGraph g;
    bool[string] made;
    // Each variant's compile, by variant.
    TaskId[size_t] compileOf;
    TaskId[size_t] archiveOf;
    // Each request's root compile and link.
    TaskId[size_t] rootCompileOf, linkOf;
    // Each request's test.
    TaskId[][size_t] testOf; // each test root's legs

    TaskId add(Action a)
    {
        if (a.id.text in made)
            return a.id;
        made[a.id.text] = true;
        // BGA12: every process the graph runs ends by its limit.
        a.action.match!(
            (ref ProcessAction p) {
                if (p.timeout == Duration.zero)
                    p.timeout = a.kind == ActionKind.test ? tools.testLimit : tools.actionLimit;
            },
            (ref other) {});
        // BGK9: what `pkg-config` searched for the flags a compile or link uses.
        if ((a.kind == ActionKind.compile || a.kind == ActionKind.link) && a.variant < plan.variants.length)
            a.searchInputs = plan.variants[a.variant].pcSearch.dup;
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

    // §7: a generator's action, made once, after its tool's build and the
    // directory of failing tools it runs with.
    TaskId[size_t] generatorOf;
    TaskId shim;
    TaskId generatorAction(size_t gi)
    {
        if (auto made_ = gi in generatorOf)
            return *made_;
        const gen = &plan.generators[gi];
        import std.digest.sha : sha256Of;
        // Root-relative, so the id, and the `$RUN/out/<id>/` paths a reader's
        // manifest records, are the same in every worktree (BGA5).
        import std.array : replace;

        const d = hexOf(sha256Of(relative(gen.directory, root) ~ "\n" ~ gen.command.replace(root, "$ROOT")))[0 .. 12];
        string[] arguments;
        foreach (arg; gen.arguments)
            arguments ~= relative(arg, root);
        TaskId id;
        if (gen.kind == GeneratorKind.shaderCompiler && gen.tool != size_t.max)
        {
            // BGG3: the tool's direct invocation, its device configuration
            // written for it by the graph rather than read through dub.
            const t = &plan.variants[gen.tool];
            const toolLink = actionId(ActionKind.link, *t);
            const vendor = t.toolchain.vendor;
            const description = taskId("generate", "device-build", "generator", vendor, d).value;
            add(Action(ActionKind.generate, description, size_t.max,
                TaskAction(InProcessAction("generate:file", ["$OUT/device.json", gen.described])),
                [DeclaredOutput("device.json")], defaultWeight(ActionKind.generate)));
            string[] argv = [inputPath(toolLink, binaryName(*t))];
            foreach (arg; gen.arguments)
                argv ~= relativeOption(arg, root);
            argv ~= "--described=" ~ inputPath(description, "device.json");
            if (tools.deviceCompiler.length)
                argv ~= "--ldc=" ~ tools.deviceCompiler;
            foreach (tool; tools.shaderTools)
                argv ~= "--tool=" ~ tool[0] ~ "=" ~ tool[1];
            argv ~= "--quiet";
            // BGG5: the device compiles report what they read, so the action is
            // keyed by its manifest, as a compile is (BGK2).
            if (tools.dependencyOutput)
                argv ~= ["--makedeps-digests=$MEASURE/digests", "--makedeps-absent=$MEASURE/absent"];
            id = taskId("generate", "shader-compile", "generator", vendor, d).value;
            add(Action(ActionKind.generate, id, gen.tool,
                TaskAction(ProcessAction(argv: argv,
                    envDelta: [EnvEntry("PATH", ""), EnvEntry("TMPDIR", "$MEASURE")] ~ tools.runtimeEnvironment.dup,
                    sandbox: SandboxPolicy.taskDirectory)),
                [DeclaredOutput(".", true)], defaultWeight(ActionKind.generate)));
            edge(toolLink, id);
            edge(description, id);
            generatorOf[gi] = id;
            return id;
        }
        if (gen.tool == size_t.max)
        {
            // The shader compiler, until its direct invocation is planned
            // from its own request: dub's command, in its package.
            id = taskId("generate", "shader-compile", "generator", plan.variants[0].toolchain.vendor, d).value;
            add(Action(ActionKind.generate, id, size_t.max,
                TaskAction(ProcessAction(argv: ["sh", "-c", gen.command], cwd: relative(gen.directory, root))),
                [DeclaredOutput(".", true)], defaultWeight(ActionKind.generate)));
            generatorOf[gi] = id;
            return id;
        }
        const t = &plan.variants[gen.tool];
        const toolCompile = add(Action(ActionKind.compile, actionId(ActionKind.compile, *t), gen.tool,
            TaskAction(ProcessAction(argv: compileArgv(*t, root, tools, TaskId.init, null),
                sandbox: SandboxPolicy.taskDirectory)),
            [DeclaredOutput(objectName(*t))], defaultWeight(ActionKind.compile)));
        const linkWeight = defaultWeight(ActionKind.link);
        const toolLink = add(Action(ActionKind.link, actionId(ActionKind.link, *t), gen.tool,
            TaskAction(ProcessAction(argv: linkArgv(*t, root, tools, toolCompile, null, linkWeight),
                envDelta: linkEnvironment(*t, tools), sandbox: SandboxPolicy.taskDirectory)),
            [DeclaredOutput(binaryName(*t))], linkWeight));
        edge(toolCompile, toolLink);
        EnvEntry[] env = [EnvEntry("PATH", "")] ~ tools.runtimeEnvironment.dup;
        if (tools.fail.length)
        {
            if (shim.empty)
            {
                shim = taskId("generate", "failing-tools", "generator", t.toolchain.vendor,
                    hexOf(sha256Of(tools.fail ~ "\n" ~ failingTools.join("\n")))[0 .. 12]).value;
                DeclaredOutput[] outs;
                foreach (name; failingTools)
                    outs ~= DeclaredOutput(name);
                add(Action(ActionKind.generate, shim, size_t.max,
                    TaskAction(InProcessAction("generate:failing-tools", ["$OUT", tools.fail] ~ failingTools)),
                    outs, defaultWeight(ActionKind.generate)));
            }
            env = [EnvEntry("PATH", "$IN(" ~ shim.text ~ ")")];
        }
        id = taskId("generate", qualifiedNameSegment(t.package_), "generator", t.toolchain.vendor, d).value;
        add(Action(ActionKind.generate, id, gen.tool,
            TaskAction(ProcessAction(argv: [inputPath(toolLink, binaryName(*t))] ~ arguments, envDelta: env,
                sandbox: SandboxPolicy.taskDirectory)),
            [DeclaredOutput(".", true)], defaultWeight(ActionKind.generate)));
        edge(toolLink, id);
        if (!shim.empty)
            edge(shim, id);
        generatorOf[gi] = id;
        return id;
    }

    // The given requests, then the generators' tools (§7).
    const requested = resolutions ~ plan.toolResolutions;
    foreach (ri, ref r; requested)
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
                        testRootArguments(*v, root, r.testRoot.testedSources))),
                    [DeclaredOutput("dub_test_root.d")], defaultWeight(ActionKind.generate));
                before ~= add(gen);
            }
            GeneratedRoot[] generated;
            foreach (gi; v.generators)
            {
                const gen = generatorAction(gi);
                before ~= gen;
                generated ~= GeneratedRoot(plan.generators[gi].output, gen);
            }
            // A string import root inherited from a dependency is filled by
            // the dependency's generator, as dub runs it first: `dmd:parser`
            // imports the `VERSION` that `dmd:lexer`'s `config.d` writes.
            foreach (gi, ref other; plan.generators)
                if (!v.generators.canFind(gi) && other.output.length
                    && v.settings.stringImportPaths.canFind!(p => trimmed(p) == other.output))
                {
                    const gen = generatorAction(gi);
                    before ~= gen;
                    generated ~= GeneratedRoot(other.output, gen);
                }
            const generatedRoot = before.length && v.role == Role.testRoot && r.testRoot.generated
                ? before[0] : TaskId.init;
            auto c = Action(ActionKind.compile, actionId(ActionKind.compile, *v), vi,
                TaskAction(ProcessAction(argv: compileArgv(*v, root, tools, generatedRoot, generated),
                    sandbox: SandboxPolicy.taskDirectory)),
                [DeclaredOutput(archivesItself(*v) ? archiveName(*v) : objectName(*v))],
                defaultWeight(ActionKind.compile));
            compileOf[vi] = add(c);
            foreach (b; before)
                edge(b, compileOf[vi]);

            if (archivesItself(*v))
                archiveOf[vi] = compileOf[vi];
            else if (v.role == Role.dependencyLibrary && v.settings.targetType != TargetType.none)
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
                envDelta: linkEnvironment(*v, tools), sandbox: SandboxPolicy.taskDirectory)),
            [DeclaredOutput(binaryName(*v))], weight);
        const linkId = add(l);
        rootCompileOf[ri] = compileOf[rootVariant];
        linkOf[ri] = linkId;
        edge(compileOf[rootVariant], linkId);
        foreach (a; archiveIds)
            edge(a, linkId);

        if (v.role == Role.testRoot && !programs.canFind!(p => p.program == ri))
            foreach (leg; tools.testLegs)
            {
                // A coverage test writes its listings to its own directory,
                // recording root-relative paths (CIC7).
                const coverage = (v.settings.options & BuildOption.coverage) != 0;
                auto testArgv = [inputPath(linkId, binaryName(*v))];
                if (coverage)
                    testArgv ~= "--DRT-covopt=dstpath:$OUT srcpath:$ROOT";
                testArgv ~= testRunnerArguments(*v, root, tools);
                if (leg.skipSlow)
                    testArgv ~= "--skip-slow";
                testArgv ~= ["-t", text(leg.threads)];
                if (auto more = v.package_ in tools.testArguments)
                    testArgv ~= (*more).dup;
                auto id = actionId(ActionKind.test, *v);
                if (leg.name.length)
                {
                    import std.array : split;

                    const named = taskId(id.text.split(":") ~ leg.name);
                    assert(named.hasValue, leg.name);
                    id = named.value;
                }
                // BGX1: a test runs in the repository root, whatever the
                // recipe's `workingDirectory`.
                auto t = Action(ActionKind.test, id, rootVariant,
                    TaskAction(ProcessAction(argv: testArgv, envDelta: tools.runtimeEnvironment.dup,
                        sandbox: SandboxPolicy.taskDirectory)),
                    coverage ? [DeclaredOutput(".", true)] : null, leg.threads);
                testOf[ri] ~= add(t);
                edge(linkId, testOf[ri][$ - 1]);
            }
    }

    // D61: a test runs the programs it declares, from their links.
    foreach (ref p; programs)
    {
        if (p.program !in linkOf || p.test !in testOf)
            return planErr!ActionGraph(ActionError(text("a test program names a request with no ",
                p.program !in linkOf ? "binary" : "test", ": ", p.variable)));
        const binary = inputPath(linkOf[p.program], binaryName(plan.variants[plan.requests[p.program][0]]));
        foreach (test; testOf[p.test])
        {
            foreach (ref a; g.actions)
                if (a.id == test)
                    a.action.match!(
                        (ref ProcessAction pa) { pa.envDelta ~= EnvEntry(p.variable, binary); },
                        (ref other) {});
            edge(linkOf[p.program], test);
        }
    }

    // CIC7: the coverage build is provisional, and the plain retry waits for
    // its failure.
    foreach (at; attempts)
    {
        if (at.coverage >= resolutions.length || at.plain >= resolutions.length
            || at.coverage !in linkOf || at.plain !in rootCompileOf)
            return planErr!ActionGraph(ActionError("a coverage attempt names a request with no test binary"));
        // A variant another request also builds is not the attempt's alone.
        bool[size_t] shared_;
        foreach (ri, vs; plan.requests)
            if (!attempts.canFind!(x => x.coverage == ri))
                foreach (vi; vs)
                    shared_[vi] = true;
        foreach (vi; plan.requests[at.coverage])
            foreach (ref a; g.actions)
                if (a.variant == vi && a.kind != ActionKind.test && vi !in shared_)
                    a.provisional = true;
        g.edges ~= TaskEdge(linkOf[at.coverage], rootCompileOf[at.plain], EdgeCondition.onFailure,
            EdgeReason.coverageFallback);
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
            failurePolicy: a.provisional ? FailurePolicy.provisional : FailurePolicy.authoritative,
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
            p.timeout, p.sandbox, p.completeEnvironment)),
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

/*
Whether `v`'s compile writes its archive itself: a dependency library built
by LDC, with one member per module, as dub's `-lib` build makes it. A link
then pulls only the members it needs, so a source library folded into both a
dependency library and its dependent links once; a single-object archive
would bring its modules in a second time.
*/
bool archivesItself(ref const Variant v) @safe pure nothrow @nogc
    => v.role == Role.dependencyLibrary && v.settings.targetType != TargetType.none;
string archiveName(ref const Variant v) @safe pure nothrow => "lib" ~ baseName(v) ~ ".a";

/// A link's planned environment: DMD finds its C driver only through `$CC`,
/// and a build action's `PATH` is empty (BGA4).
EnvEntry[] linkEnvironment(ref const Variant v, const Tools tools) @safe pure nothrow
    => v.platform.compiler != "ldc" && tools.cc.length ? [EnvEntry("CC", tools.cc)] : null;
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

// The test-root generator's arguments: the package directory relative to
// the root, the module's output path, the import roots relative to the
// package, `--`, and the tested sources relative to the package.
// The name `-fuse-ld=` takes for the linker at `path`: `ld.lld` is `lld`.
string linkerName(string path) @safe pure nothrow
{
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/')
        --slash;
    const base = path[slash .. $];
    return base.startsWith("ld.") ? base[3 .. $] : base;
}

string directoryOf(string path) @safe pure nothrow
{
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/')
        --slash;
    return slash > 1 ? path[0 .. slash - 1] : "/";
}

string[] testRootArguments(ref const Variant v, string root, const string[] tested) @safe
{
    string[] arguments = [relative(v.directory, root), "$OUT/dub_test_root.d"];
    foreach (p; v.settings.importPaths)
        if (p.startsWith(v.directory ~ "/"))
        {
            auto r = p[v.directory.length + 1 .. $];
            while (r.length && r[$ - 1] == '/')
                r = r[0 .. $ - 1];
            arguments ~= r;
        }
    arguments ~= "--";
    return arguments ~ tested;
}

// A string import root a generator fills, and the generator's action: the
// compile reads the action's output in the root's place (BGG2).
struct GeneratedRoot
{
    string root;
    TaskId producer;
}

// The compiler's arguments for a variant's one compile.
string[] compileArgv(ref const Variant v, string root, const Tools tools, TaskId generatedRoot,
    const GeneratedRoot[] generated) @safe
{
    const s = &v.settings;
    const ldc = v.platform.compiler == "ldc";
    string[] argv = [tools.compiler];
    if (archivesItself(v))
        // One member per module, as dub builds a library, so a link pulls in
        // only the modules it needs: LDC names each by its module, written
        // through a scratch directory it empties again; DMD writes the
        // archive itself.
        argv ~= ldc ? ["-lib", "-oq", "-od=$MEASURE/objects", "-cleanup-obj", "-of=$OUT/" ~ archiveName(v)]
            : ["-lib", "-of=$OUT/" ~ archiveName(v)];
    else
        argv ~= ["-c"] ~ (ldc ? ["-singleobj"] : null) ~ ["-of=$OUT/" ~ objectName(v)];
    // BGK2: the manifest, beside the action's measurements.
    if (ldc && tools.dependencyOutput)
        argv ~= ["--makedeps=$MEASURE/deps", "--makedeps-absent=$MEASURE/absent",
            "--makedeps-digests=$MEASURE/digests"];
    if (tools.config.length)
        argv ~= "-conf=" ~ tools.config;
    // BGA5: the root maps to `.` in what the outputs record.
    if (ldc)
        argv ~= "--ffile-prefix-map=$ROOT=.";
    if (ldc)
        foreach (m; tools.prefixMaps)
            argv ~= "--ffile-prefix-map=" ~ m;
    if (ldc && tools.cc.length)
        argv ~= "-gcc=" ~ tools.cc;
    argv ~= optionFlags(s.options, ldc);
    // Tests run on several threads, so LDC counts coverage atomically (CIC7).
    if (ldc && (s.options & BuildOption.coverage))
        argv ~= "--cov-increment=atomic";
    foreach (f; s.dflags)
        argv ~= f;
    argv ~= tools.extraFlags;
    foreach (p; s.importPaths)
        argv ~= "-I=" ~ relative(p, root);
    // The C preprocessor's include roots, as dub passes them (ImportC).
    foreach (p; s.cImportPaths)
        argv ~= (ldc ? "-P-I" : "-P=-I") ~ relative(p, root);
    foreach (p; s.stringImportPaths)
    {
        string path = relative(p, root);
        foreach (ref g; generated)
            if (trimmed(p) == g.root)
                path = "$IN(" ~ g.producer.text ~ ")";
        argv ~= "-J=" ~ path;
    }
    foreach (id; s.versions)
        argv ~= (ldc ? "-d-version=" : "-version=") ~ id;
    foreach (id; s.debugVersions)
        argv ~= (ldc ? "-d-debug=" : "-debug=") ~ id;
    foreach (f; s.sourceFiles)
        if (!isLinkerInput(f))
            argv ~= relative(f, root);
    if (!generatedRoot.empty)
    {
        // The generated module lies in its producer's output directory,
        // which the run chooses: mapped to a fixed name, as the root is.
        if (ldc)
            argv ~= "--ffile-prefix-map=$IN(" ~ generatedRoot.text ~ ")=generated";
        argv ~= inputPath(generatedRoot, "dub_test_root.d");
    }
    return argv;
}

// The link's arguments: the root's object, the archives in link order, the
// libraries and linker flags, and the linker's thread count (BGA8).
string[] linkArgv(ref const Variant v, string root, const Tools tools, TaskId compile,
    const string[] archives, uint threads) @safe
{
    const s = &v.settings;
    // dub links with the compiler flags too; the tools named here come
    // after them, so they win over a recipe's `--linker=lld`.
    // dub turns build options into compiler flags before it links.
    string[] argv = [tools.compiler];
    if (tools.config.length)
        argv ~= "-conf=" ~ tools.config;
    argv ~= optionFlags(s.options, v.platform.compiler == "ldc");
    foreach (f; s.dflags)
        argv ~= f;
    argv ~= tools.extraFlags;
    argv ~= ["-of=$OUT/" ~ binaryName(v), inputPath(compile, objectName(v))];
    if (v.platform.compiler == "ldc")
    {
        if (tools.cc.length)
            argv ~= "-gcc=" ~ tools.cc;
        // GCC takes `-fuse-ld=` by name only: the linker's directory goes
        // first on the driver's program path, so the name finds it there.
        if (tools.linker.length)
            argv ~= ["--linker=" ~ linkerName(tools.linker), "-Xcc=-B" ~ directoryOf(tools.linker)];
    }
    // DMD names its C driver only through `$CC` (`linkEnvironment`) and the
    // linker only through that driver's options.
    else if (tools.linker.length)
        argv ~= ["-Xcc=-B" ~ directoryOf(tools.linker), "-Xcc=-fuse-ld=" ~ linkerName(tools.linker)];
    argv ~= archives;
    foreach (f; s.sourceFiles)
        if (isLinkerInput(f))
            argv ~= relative(f, root);
    foreach (f; s.linkerFiles)
        argv ~= relative(f, root);
    foreach (dir; tools.libraryPath)
        argv ~= "-L-L" ~ dir;
    foreach (lib; s.libs)
        argv ~= "-L-l" ~ lib;
    foreach (f; s.lflags)
        argv ~= "-L" ~ f;
    // lld's thread count: only a link that names lld takes it, and the C
    // driver's own linker (macOS's `ld`) refuses it.
    if (tools.linker.length)
        argv ~= "-L--threads=" ~ text(threads);
    return argv;
}

/*
BGX1: what the test runner's compile-time and extracted modes need, from
the variant's resolved settings, so the runner never runs dub (`--no-dub`,
test runner TRX2): the compiler, the import and string import paths, the
versions and dflags, and a probe directory in the action's measurement
directory.
*/
string[] testRunnerArguments(ref const Variant v, string root, const Tools tools) @safe
{
    const s = &v.settings;
    string[] args = ["--no-dub", "--probe-dir=$MEASURE/probe"];
    if (tools.compiler.startsWith("/"))
        args ~= "--compiler=" ~ tools.compiler;
    foreach (p; s.importPaths)
        args ~= "--import-path=" ~ relative(p, root);
    foreach (p; s.stringImportPaths)
        args ~= "--string-import-path=" ~ relative(p, root);
    foreach (p; s.cImportPaths)
        args ~= "--dflag=-P-I" ~ relative(p, root);
    foreach (id; s.versions)
        args ~= "--version=" ~ id;
    foreach (f; s.dflags)
        args ~= "--dflag=" ~ f;
    return args;
}

// An argument `--name=<path>` with the path made relative to the root,
// as BGA5 passes paths; any other argument as given.
string relativeOption(string arg, string root) @safe pure nothrow
{
    foreach (i, c; arg)
        if (c == '=')
            return arg[0 .. i + 1] ~ relative(arg[i + 1 .. $], root);
    return relative(arg, root);
}

string trimmed(string path) @safe pure nothrow @nogc
{
    while (path.length > 1 && path[$ - 1] == '/')
        path = path[0 .. $ - 1];
    return path;
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
        string[2][] requests;
        foreach (p; packages)
            requests ~= [p, "unittest"];
        return graphWith(requests);
    }

    // The same packages, each request a sub-package and a build type.
    private ActionGraph graphWith(const string[2][] requests, const CoverageAttempt[] attempts = null,
        const Tools tools = Tools.init, const TestProgram[] programs = null) @safe
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
        foreach (q; requests)
        {
            auto r = resolve(ResolveRequest(directory: "/r", subPackage: q[0], buildType: q[1],
                platform: BuildPlatform(["linux", "posix"], ["x86_64"], "ldc", "ldc2", 2111, "1.41.0"),
                testRoot: true), tree);
            assert(r.hasValue, r.hasError ? r.error.message : null);
            rs ~= r.value;
        }
        const plan = planVariants(rs, PlanOptions(ToolchainIdentity("ldc", "toolchain-1")), tree);
        assert(plan.hasValue);
        auto g = planActions(plan.value, rs, "/r", tools, attempts, programs);
        assert(g.hasValue, g.hasError ? g.error.message : null);
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
    // version): four compiles, the libraries' two writing their archives
    // with LDC, two links, two tests, and the two test-root modules.
    assert(count(g, ActionKind.compile) == 4);
    assert(count(g, ActionKind.archive) == 0);
    import std.algorithm.searching : algoCount = count;
    assert(g.actions.algoCount!(a => a.outputs.length && a.outputs[0].path.endsWith(".a")) == 2);
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

    // A test run carries its claimed thread count, and so does a link that
    // names lld; the C driver's own linker is given none.
    import std.algorithm.searching : startsWith;

    const withLld = graphWith([[":t1", "unittest"]], null, Tools(linker: "/lld/bin/ld.lld"));
    foreach (lld, graph; [a, withLld])
        foreach (ref act; graph.actions)
        {
            const argv = act.action.match!((ref const ProcessAction p) => p.argv.dup, (_) => string[].init);
            if (act.kind == ActionKind.link)
                assert(lld ? argv.canFind("-L--threads=2")
                    : !argv.canFind!(f => f.startsWith("-L--threads")), text(argv));
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

@("build_graph.actions.planActions.coverageFallback")
@safe unittest
{
    import sparkles.build_primitives.task.model : FailurePolicy;

    // Oracle 14, invariant 7: a coverage attempt and its plain fallback,
    // against the plain test alone. The plain compile behind the `onFailure`
    // edge is the one the plain test compiles: one id and one argument
    // vector, so one result serves both.
    const attempt = graphWith([[":t1", "unittest-cov"], [":t1", "unittest"]], [CoverageAttempt(0, 1)]);
    const plain = graphOf(":t1");

    TaskId plainCompile;
    foreach (ref a; plain.actions)
        if (a.kind == ActionKind.compile && a.id.text.startsWith("compile:r.t1:"))
            plainCompile = a.id;
    const inAttempt = attempt.find(plainCompile);
    assert(inAttempt !is null, "the plain compile is in the attempt's graph");
    assert(inAttempt.action == plain.find(plainCompile).action && !inAttempt.provisional);

    // The fallback edge: from the coverage link to the plain compile.
    size_t fallbacks;
    foreach (ref e; attempt.edges)
        if (e.condition == EdgeCondition.onFailure)
        {
            ++fallbacks;
            const from = attempt.find(e.prerequisite);
            assert(from.kind == ActionKind.link && from.provisional && e.dependent == plainCompile);
            assert(e.reason == EdgeReason.coverageFallback);
        }
    assert(fallbacks == 1);
    foreach (ref e; plain.edges)
        assert(e.condition == EdgeCondition.onSuccess);

    // The coverage build is provisional; its test, and the plain chain, are
    // not. The coverage compile counts atomically, and its test writes its
    // listings to its own directory (CIC7).
    foreach (n; taskNodes(attempt))
    {
        const a = attempt.find(n.id);
        assert((n.failurePolicy == FailurePolicy.provisional) == a.provisional);
        const argv = a.action.match!((ref const ProcessAction p) => p.argv.dup, (_) => string[].init);
        if (a.provisional && a.kind == ActionKind.compile)
            assert(argv.canFind("-cov") && argv.canFind("--cov-increment=atomic"));
        if (a.kind == ActionKind.test && attempt.find(e(attempt, a.id)).provisional)
            assert(argv.canFind("--DRT-covopt=dstpath:$OUT srcpath:$ROOT"));
    }
}

version (unittest)
    // The prerequisite of the edge into `to`.
    private TaskId e(ref const ActionGraph g, TaskId to) @safe
    {
        foreach (ref x; g.edges)
            if (x.dependent == to)
                return x.prerequisite;
        assert(0);
    }

/// A single-file generator (§7): its tool is built as an application, it runs
/// with its output as `$OUT` and failing tools on its `PATH`, and the compile
/// that reads its string import root reads that output instead (BGG2).
@("build_graph.actions.planActions.singleFileGenerator")
@safe unittest
{
    import std.algorithm.searching : count;

    auto tree = memoryTree([
        "/r/dub.sdl": "name \"r\"\nsubPackage \"t\"\nsubPackage \"g\"\n",
        "/r/t/dub.sdl": "name \"t\"\ndependency \"r:g\" path=\"..\"\n"
            ~ "configuration \"library\" {\n}\nconfiguration \"unittest\" {\n}\n",
        "/r/t/source/t.d": "module t;\n",
        "/r/g/dub.sdl": "name \"g\"\nstringImportPaths \"gen\"\n"
            ~ "preGenerateCommands `\"$DUB_EXE\" \"--compiler=$DC\" --single \"${PACKAGE_DIR}/tool.d\" -- "
            ~ "\"${PACKAGE_DIR}/gen\" \"${PACKAGE_DIR}/VERSION\"`\n",
        "/r/g/source/g.d": "module g;\n",
        "/r/g/tool.d": "/+ dub.sdl:\n    name \"tool\"\n+/\nmodule tool;\nvoid main() {}\n",
    ]);
    auto r = resolve(ResolveRequest(directory: "/r", subPackage: ":t", buildType: "unittest",
        platform: BuildPlatform(["linux", "posix"], ["x86_64"], "ldc", "ldc2", 2111, "1.41.0"), testRoot: true), tree);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    const plan = planVariants([r.value], PlanOptions(ToolchainIdentity("ldc", "toolchain-1")), tree);
    assert(plan.hasValue, plan.hasError ? plan.error.message : null);
    assert(plan.value.generators.length == 1 && plan.value.generators[0].output == "/r/g/gen");
    auto g = planActions(plan.value, [r.value], "/r", Tools(fail: "/bin/false"));
    assert(g.hasValue, g.hasError ? g.error.message : null);

    const(Action)* of(string prefix)
    {
        foreach (ref a; g.value.actions)
            if (a.id.text.startsWith(prefix))
                return &a;
        assert(false, prefix);
    }
    const gen = of("generate:r.tool:generator:");
    const argv = gen.action.match!((ref const ProcessAction p) => p.argv, (_) => null);
    assert(argv.length == 3 && argv[0].startsWith("$IN(link:r.tool:application:") && argv[1 .. $] == ["$OUT", "g/VERSION"],
        text(argv));
    const env = gen.action.match!((ref const ProcessAction p) => p.envDelta, (_) => null);
    assert(env.length == 1 && env[0].name == "PATH" && env[0].value.startsWith("$IN(generate:failing-tools:"));

    const compile = of("compile:r.g:library:");
    const cargv = compile.action.match!((ref const ProcessAction p) => p.argv, (_) => null);
    assert(cargv.canFind("-J=$IN(" ~ gen.id.text ~ ")"), text(cargv));
    assert(g.value.edges.canFind!(e => e.prerequisite == gen.id && e.dependent == compile.id));
    assert(g.value.actions.count!(a => a.kind == ActionKind.generate && a.id.text.startsWith("generate:r.tool")) == 1);

    // `t` inherits `g`'s root, and reads the same output after the same
    // generator, which runs once.
    const dependent = of("compile:r.t:test-root:");
    const dargv = dependent.action.match!((ref const ProcessAction p) => p.argv, (_) => null);
    assert(dargv.canFind("-J=$IN(" ~ gen.id.text ~ ")") && !dargv.canFind("-J=g/gen"), text(dargv));
    assert(g.value.edges.canFind!(e => e.prerequisite == gen.id && e.dependent == dependent.id));
    assert(g.value.actions.count!(a => a.id == gen.id) == 1);
}

/// D61: a program a test runs is linked, its own tests do not run, and the test
/// names it by a variable whose value is the link's binary.
@("build_graph.actions.planActions.testPrograms")
@safe unittest
{
    const g = graphWith([[":t1", "unittest"], [":t2", "unittest"]], null, Tools.init,
        [TestProgram(test: 0, program: 1, variable: "T2_BINARY")]);
    assert(count(g, ActionKind.test) == 1);
    const(Action)* test, link2;
    foreach (ref a; g.actions)
    {
        if (a.kind == ActionKind.test)
            test = &a;
        if (a.kind == ActionKind.link && a.id.text.startsWith("link:r.t2:"))
            link2 = &a;
    }
    assert(test !is null && test.id.text.startsWith("test:r.t1:") && link2 !is null);
    const env = test.action.match!((ref const ProcessAction p) => p.envDelta, (_) => null);
    assert(env.length == 1 && env[0].name == "T2_BINARY"
        && env[0].value == "$IN(" ~ link2.id.text ~ ")/" ~ link2.outputs[0].path, text(env));
    assert(g.edges.canFind!(e => e.prerequisite == link2.id && e.dependent == test.id));
}

@("build_graph.actions.planActions.timeLimits")
@safe unittest
{
    static Duration limitOf(ref const Action a) => a.action.match!(
        (ref const ProcessAction p) => p.timeout, (_) => Duration.zero);

    // BGA12: a test ends by its limit, every other process by the backstop.
    const g = graphOf(":t1");
    size_t processes;
    foreach (ref a; g.actions)
        if (a.action.match!((ref const ProcessAction _) => true, (_) => false))
        {
            ++processes;
            assert(limitOf(a) == (a.kind == ActionKind.test ? 20.minutes : 30.minutes), a.id.text);
        }
    assert(processes);

    // Zero sets none; the limits are the caller's.
    const none = graphWith([[":t1", "unittest"]], null,
        Tools(testLimit: Duration.zero, actionLimit: 5.minutes));
    foreach (ref a; none.actions)
        if (a.kind == ActionKind.test)
            assert(limitOf(a) == Duration.zero);
        else if (a.kind == ActionKind.compile)
            assert(limitOf(a) == 5.minutes);
}

/// BGX1: a test takes what the runner's compile-time modes need as
/// arguments, and never runs dub.
@("build_graph.actions.planActions.testRunnerArguments")
@safe unittest
{
    const g = graphOf(":t1");
    foreach (ref a; g.actions)
        if (a.kind == ActionKind.test)
        {
            const argv = a.action.match!((ref const ProcessAction p) => p.argv, (_) => null);
            assert(argv.canFind("--no-dub") && argv.canFind("--probe-dir=$MEASURE/probe"), text(argv));
            assert(argv.canFind("--import-path=t1/source") && argv.canFind("--import-path=mid/source"), text(argv));
            assert(argv.canFind("--version=T1Only"), text(argv));
            return;
        }
    assert(false, "no test action");
}

/// CIC11, CIC14: each leg is a test action of its own, claiming its `-t`.
@("build_graph.actions.planActions.testLegs")
@safe unittest
{
    import std.algorithm.searching : endsWith;

    const g = graphWith([[":t1", "unittest"]], null,
        Tools(testLegs: [TestLeg(1, true, "serial"), TestLeg(8, true)]));
    const(Action)[] legs;
    foreach (ref a; g.actions)
        if (a.kind == ActionKind.test)
            legs ~= a;
    assert(legs.length == 2);
    foreach (ref a; legs)
    {
        const argv = a.action.match!((ref const ProcessAction p) => p.argv, (_) => null);
        const serial = a.id.text.endsWith(":serial");
        assert(argv.canFind("--skip-slow"), text(argv));
        assert(argv[$ - 2 .. $] == ["-t", serial ? "1" : "8"], text(argv));
        assert(a.weight == (serial ? 1 : 8));
    }
    assert(legs[0].id.text.endsWith(":serial") != legs[1].id.text.endsWith(":serial"));
}
