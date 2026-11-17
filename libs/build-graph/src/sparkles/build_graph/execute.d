/**
Local execution of an action graph (build-graph SPEC BGA4–BGA7, BGA10;
PLAN E3): the actions $(REF planActions, sparkles,build_primitives,plan,actions)
lowered, made concrete for one run directory and run on the task-DAG
executor.

$(LREF executionNodes) replaces each action's placeholders: `$ROOT` by the
worktree, `$OUT` by the action's output directory beneath the run
directory, `$MEASURE` by its measurement directory, and `$IN(<id>)` by
another action's output directory. It gives each action a complete
environment (BGA4): compiles, archives and links run with a fixed
`SOURCE_DATE_EPOCH`, `TERM` and `NO_COLOR` and an empty `PATH`, and inherit
nothing; generators and tests run with the environment the caller declares
for them (BGX1).

$(LREF ActionDriver) creates each action's directories through the VFS
before it runs (BGF1), and runs the test-root generator in process: it
reads each tested source's module name and writes dub's test-root module.
Each action's standard output and error are kept in its directory's
`output.log`, with its exit status in its task record (BGA7).

There is no store yet (§6): every run builds what it plans, and a run
directory is the run's alone.
*/
module sparkles.build_graph.execute;

import std.algorithm.searching : canFind, startsWith;
import std.array : replace;
import std.conv : text;
import std.sumtype : match;

import sparkles.build_graph.actions : Action, ActionGraph, ActionKind;
import sparkles.build_primitives.task.action : EnvEntry, InProcessAction, InertAction, ProcessAction,
    TaskAction;
import sparkles.build_primitives.task.model : TaskId, TaskNode;

/// Where a run puts what its actions make.
struct RunLayout
{
    string root;         /// the worktree, absolute
    string runDirectory; /// absolute: `out/` and `measure/` per action

    /// The output directory of action `id`: its `$OUT`.
    string outOf(TaskId id) const @safe pure nothrow => runDirectory ~ "/out/" ~ idPath(id);

    /// The measurement directory of action `id`: its `$MEASURE`.
    string measureOf(TaskId id) const @safe pure nothrow => runDirectory ~ "/measure/" ~ idPath(id);

    // A task id as a relative path, each segment a component.
    private static string idPath(TaskId id) @safe pure nothrow
    {
        import sparkles.build_primitives.task.process : sandboxPath;

        return sandboxPath(id);
    }
}

/// The fixed `SOURCE_DATE_EPOCH` of every build action (BGA4).
enum sourceDateEpoch = "1";

/**
The environment of a compile, archive or link (BGA4): complete, with the
date fixed for `__DATE__` and `__TIME__`, the diagnostics' terminal fixed,
and an empty `PATH`, so the compiler finds no tool by searching.
*/
EnvEntry[] buildEnvironment() @safe pure nothrow
{
    EnvEntry[] env = [
        EnvEntry("SOURCE_DATE_EPOCH", sourceDateEpoch),
        EnvEntry("TERM", "dumb"),
        EnvEntry("NO_COLOR", "1"),
        EnvEntry("PATH", ""),
    ];
    version (OSX)
        env ~= EnvEntry("MACOSX_DEPLOYMENT_TARGET", "11.0");
    return env;
}

/**
`g`'s actions as task nodes ready to run in `layout`: placeholders replaced,
each process with its complete environment. `declared` is the environment
of generators and tests (BGX1), which this module takes as given.
*/
TaskNode[] executionNodes(ref const ActionGraph g, const RunLayout layout, const EnvEntry[] declared) @safe
{
    import sparkles.build_graph.actions : taskNodes;

    auto nodes = taskNodes(g);
    foreach (ref n; nodes)
    {
        const a = g.find(n.id);
        assert(a !is null);
        const id = n.id;
        const build = a.kind == ActionKind.compile || a.kind == ActionKind.archive || a.kind == ActionKind.link;
        auto concrete = a.action.match!(
            (ref const ProcessAction p) {
                ProcessAction q;
                foreach (arg; p.argv)
                    q.argv ~= expand(arg, layout, id);
                q.cwd = p.cwd.length ? expand(p.cwd, layout, id) : layout.root;
                if (q.cwd.length && !q.cwd.startsWith("/"))
                    q.cwd = layout.root ~ "/" ~ q.cwd;
                q.envDelta = build ? buildEnvironment() : declared.dup;
                q.completeEnvironment = true;
                q.stdin = p.stdin;
                q.timeout = p.timeout;
                q.sandbox = p.sandbox;
                return TaskAction(q);
            },
            (ref const InProcessAction i) {
                string[] arguments;
                foreach (arg; i.arguments)
                    arguments ~= expand(arg, layout, id);
                return TaskAction(InProcessAction(i.handler, arguments));
            },
            (ref const InertAction x) => TaskAction(InertAction(x.note)));
        // `SumType` assignment is `@system` only for what its members could hold.
        (() @trusted { n.action = concrete; })();
    }
    return nodes;
}

/// `arg` with the run's placeholders replaced, for the action `self`.
string expand(string arg, const RunLayout layout, TaskId self) @safe
{
    import std.array : split;
    import sparkles.build_primitives.task.model : taskId;

    string result;
    size_t i;
    while (i < arg.length)
    {
        if (arg[i] != '$')
        {
            result ~= arg[i++];
            continue;
        }
        const rest = arg[i .. $];
        if (rest.startsWith("$IN("))
        {
            size_t close = 4;
            while (close < rest.length && rest[close] != ')')
                ++close;
            const producer = taskId(rest[4 .. close].split(":"));
            assert(producer.hasValue, "a `$IN` names a task id");
            result ~= layout.outOf(producer.value);
            i += close + 1;
        }
        else if (rest.startsWith("$ROOT"))
        {
            result ~= layout.root;
            i += 5;
        }
        else if (rest.startsWith("$OUT"))
        {
            result ~= layout.outOf(self);
            i += 4;
        }
        else if (rest.startsWith("$MEASURE"))
        {
            result ~= layout.measureOf(self);
            i += 8;
        }
        else
            result ~= arg[i++];
    }
    return result;
}

/**
The text of dub's test-root module for the modules `modules`: it lists them
in `allModules`, which the test runner reads, and holds dub's `main`.
*/
string testRootModule(scope const(string)[] modules) @safe pure
{
    string imports, list;
    foreach (i, m; modules)
    {
        imports ~= "static import " ~ m ~ ";\n";
        list ~= (i ? ",\n" : "") ~ "    " ~ m;
    }
    return "\ndeprecated // allow silently using deprecated symbols\nmodule dub_test_root;\n\nimport std.typetuple;\n\n"
        ~ imports ~ "\nalias allModules = TypeTuple!(\n" ~ list ~ "\n);\n\n" ~ testRootMain;
}

// dub's `main` for a generated test root, as dub writes it.
private enum testRootMain = "\tversion(D_BetterC) {
\t\textern(C) int main() {
\t\t\tforeach (module_; allModules) {
\t\t\t\tforeach (unitTest; __traits(getUnitTests, module_)) {
\t\t\t\t\tunitTest();
\t\t\t\t}
\t\t\t}
\t\t\timport core.stdc.stdio : puts;
\t\t\tputs(\"All unit tests have been run successfully.\");
\t\t\treturn 0;
\t\t}
\t} else {
\t\tvoid main() {
\t\t\tversion (D_Coverage) {
\t\t\t} else {
\t\t\t\timport std.stdio : writeln;
\t\t\t\twriteln(\"All unit tests have been run successfully.\");
\t\t\t}
\t\t}
\t\tshared static this() {
\t\t\tversion (Have_tested) {
\t\t\t\timport tested;
\t\t\t\timport core.runtime;
\t\t\t\timport std.exception;
\t\t\t\tRuntime.moduleUnitTester = () => true;
\t\t\t\tenforce(runUnitTests!allModules(new ConsoleTestResultWriter), \"Unit tests failed.\");
\t\t\t}
\t\t}
\t}
";

/**
The module a D source declares, or, without a declaration, the name dub
gives it: its path beneath the first of `importRoots` that holds it, with
`/` as `.` and without `.d`.
*/
string moduleNameOf(string relativePath, const(char)[] source, scope const(string)[] importRoots) @safe
{
    import sparkles.d_source.tokens : TokenKind, tokenize;

    const ts = tokenize(source);
    foreach (i, t; ts)
    {
        if (!(t == "module"))
            continue;
        string name;
        foreach (u; ts[i + 1 .. $])
        {
            if (u == ";")
                return name;
            if (u.kind == TokenKind.identifier || u == ".")
                name ~= u.text;
        }
        break;
    }
    string path = relativePath;
    foreach (r; importRoots)
        if (path.startsWith(r ~ "/"))
        {
            path = path[r.length + 1 .. $];
            break;
        }
    if (path.length > 2 && path[$ - 2 .. $] == ".d")
        path = path[0 .. $ - 2];
    return path.replace("/", ".");
}

version (Posix):

import sparkles.build_primitives.task.executor : RunResult, TaskContext;
import sparkles.build_primitives.task.model : TaskOutcome;
import sparkles.build_primitives.task.process : ProcessDriver, ProcessDriverOptions;
import sparkles.event_horizon.sched : Sched;

/**
The action driver of a local run: makes each action's output and
measurement directories through the VFS (BGF1), runs the test-root
generator in process, and runs every process through the task DAG's
process driver, keeping its output in `<out>/output.log` (BGA7).
*/
struct ActionDriver
{
    import sparkles.base.vfs.handles : Dir;
    import sparkles.base.vfs.types : Rights;
    import sparkles.event_horizon.sys : BlockingVfs;

    @disable this();
    @disable this(this);

    private RunLayout layout;
    private ProcessDriver* process;
    private BlockingVfs* vfs;
    private Dir!(BlockingVfs, Rights.all) run_;
    private Dir!(BlockingVfs, Rights.readOnly) worktree;
    private string failure;

    /**
    A driver for `nodes` in `layout`. The run directory and the worktree
    are the two roots it opens (BGF2): the run directory with every right,
    as the store will be, and the worktree read-only.
    */
    this(RunLayout layout, const TaskNode[] nodes) @safe
    {
        import core.lifetime : move;
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, SymlinkPolicy;

        this.layout = layout;
        vfs = new BlockingVfs;
        auto made = openRoot!(Rights.all)(vfs, layout.runDirectory, ambientAuthority());
        if (made.hasError)
            failure = "cannot open the run directory " ~ layout.runDirectory;
        else
            run_ = move(made.value);
        auto tree = openRoot!(Rights.readOnly)(vfs, layout.root, ambientAuthority(),
            ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject, crossMounts: true));
        if (tree.hasError)
            failure = "cannot open the worktree " ~ layout.root;
        else
            worktree = move(tree.value);
        process = new ProcessDriver(ProcessDriverOptions(repoRoot: layout.root,
            spillPath: (ref const TaskNode n) => layout.outOf(n.id) ~ "/output.log"), nodes.length);
    }

    /// Why the driver cannot run anything; null when it can.
    string error() const @safe pure nothrow @nogc => failure;

    /// The process driver, whose records hold each process's end and status.
    ref ProcessDriver processes() return @safe pure nothrow @nogc => *process;

    /// Runs `ctx`'s action (the executor's entry point).
    TaskOutcome run(ref TaskContext!Sched ctx)
    {
        import sparkles.build_primitives.task.model : FailureReason, Failed;

        if (failure.length || !makeDirectories(ctx.node.id))
            return TaskOutcome(Failed(FailureReason.contract));
        return process.run(ctx);
    }

    // The action's `out` and `measure` directories, beneath the run's root.
    private bool makeDirectories(TaskId id) @safe
    {
        foreach (dir; [layout.outOf(id), layout.measureOf(id)])
            if (run_.walkAll(dir[layout.runDirectory.length + 1 .. $]).hasError)
                return false;
        return true;
    }

    /*
    The test-root generator: its arguments are the package directory
    relative to the worktree, the output path, the import roots relative
    to the package, `--`, then the tested sources relative to the package.
    Reads each source's module name through the worktree's root and writes
    the module into the output directory.
    */
    TaskOutcome generateTestRoot(ref TaskContext!Sched ctx, const ref InProcessAction a) @system
    {
        import sparkles.base.vfs.types : OpenMode;
        import sparkles.build_primitives.task.model : FailureReason, Failed, OutputStream, Succeeded;

        TaskOutcome fail(string why)
        {
            ctx.output(OutputStream.stderr, why);
            return TaskOutcome(Failed(FailureReason.exitStatus, 1));
        }
        if (a.arguments.length < 3)
            return fail("generate:test-root-module: too few arguments");
        const packageDir = a.arguments[0];
        const output = a.arguments[1];
        size_t at = 2;
        string[] roots;
        while (at < a.arguments.length && a.arguments[at] != "--")
            roots ~= a.arguments[at++];
        string[] modules;
        foreach (source; a.arguments[at + 1 .. $])
        {
            const path = packageDir.length && packageDir != "." ? packageDir ~ "/" ~ source : source;
            string text_;
            if (!readWorktree(path, text_))
                return fail("generate:test-root-module: cannot read " ~ path);
            modules ~= moduleNameOf(source, text_, roots);
        }
        const out_ = output[layout.runDirectory.length + 1 .. $];
        size_t slash = out_.length;
        while (slash > 0 && out_[slash - 1] != '/')
            --slash;
        auto dir = run_.walkAll(out_[0 .. slash - 1]);
        if (dir.hasError)
            return fail("generate:test-root-module: cannot open " ~ output);
        if (dir.value.writeFileAtomic(out_[slash .. $], testRootModule(modules)).hasError)
            return fail("generate:test-root-module: cannot write " ~ output);
        return TaskOutcome(Succeeded());
    }

    private bool readWorktree(string path, out string text_) @safe
    {
        import sparkles.base.vfs.types : OpenMode;

        size_t slash = path.length;
        while (slash > 0 && path[slash - 1] != '/')
            --slash;
        bool readFrom(D)(ref D dir, const(char)[] name)
        {
            auto file = dir.openFile!(OpenMode.read)(name);
            if (file.hasError)
                return false;
            ubyte[] buffer = new ubyte[4096];
            size_t n;
            for (;;)
            {
                if (n == buffer.length)
                    buffer.length *= 2;
                auto r = file.value.read(buffer[n .. $]);
                if (r.hasError)
                    return false;
                if (r.value == 0)
                    break;
                n += r.value;
            }
            text_ = (() @trusted => cast(string) buffer[0 .. n])();
            return true;
        }
        if (slash == 0)
            return readFrom(worktree, path);
        auto dir = worktree.walk(path[0 .. slash - 1]);
        return !dir.hasError && readFrom(dir.value, path[slash .. $]);
    }
}

/**
Runs `nodes` (from $(LREF executionNodes)) with their edges on a scheduler
of their own, reporting each task's lines to `writer` through the plain
reporter, at most `capacity` weight at a time.
*/
RunResult runActions(W)(TaskNode[] nodes, const ActionGraph g, RunLayout layout, ref W writer,
    uint capacity)
{
    import sparkles.build_primitives.task.executor : ExecutorOptions, runGraph;
    import sparkles.build_primitives.task.graph : TaskGraphBuilder;
    import sparkles.build_primitives.task.process : EventChannel, MonotonicClock;
    import sparkles.build_primitives.task.reporter : consumeEvents;
    import sparkles.build_primitives.task.reporter_plain : PlainOptions, PlainReporter;
    import sparkles.event_horizon.loop : LoopConfig;
    import sparkles.event_horizon.sched : SchedOptions;
    import sparkles.event_horizon.scope_ : withScope;

    TaskGraphBuilder builder;
    foreach (n; nodes)
        builder.add(n);
    foreach (e; g.edges)
        builder.add(e);
    auto built = builder.build();
    if (built.hasError)
        return RunResult(exitCode: 2);
    auto graph = built.value;

    Sched s;
    if (Sched.create(s, SchedOptions(stackSize: 256 * 1024), LoopConfig()).hasError)
        return RunResult(exitCode: 2);
    auto driver = new ActionDriver(layout, nodes); // the generator's handler holds its address
    if (driver.error.length)
        return RunResult(exitCode: 2);
    driver.processes.register("generate:test-root-module",
        (ref TaskContext!Sched ctx, const ref InProcessAction a) => driver.generateTestRoot(ctx, a));
    auto reporter = PlainReporter!W(&writer, &graph, PlainOptions(timings: false));
    auto sink = new EventChannel;
    MonotonicClock clock;
    RunResult result;
    auto ran = s.run(() {
        cast(void) withScope!((ref sc) {
            sc.spawn(() { consumeEvents(s, *sink, reporter); });
            result = runGraph(s, clock, graph, *driver, *sink, ExecutorOptions(capacity: capacity));
            sink.close();
        })(s);
    });
    if (ran.hasError)
        return RunResult(exitCode: 2);
    return result;
}

/// Placeholders become the run's paths; a build action's environment is
/// complete and fixed, a test's is the one declared.
@("build_graph.execute.executionNodes")
@safe unittest
{
    import sparkles.build_graph.actions : DeclaredOutput, defaultWeight;
    import sparkles.build_primitives.task.model : taskId;

    const compile = taskId("compile", "r.leaf", "library", "ldc", "abc").value;
    const test = taskId("test", "r.t1", "test-root", "ldc", "def").value;
    ActionGraph g;
    g.actions ~= Action(ActionKind.compile, compile, 0,
        TaskAction(ProcessAction(argv: ["ldc2", "--ffile-prefix-map=$ROOT=.", "-of=$OUT/leaf.o"])),
        [DeclaredOutput("leaf.o")], defaultWeight(ActionKind.compile));
    g.actions ~= Action(ActionKind.test, test, 1,
        TaskAction(ProcessAction(argv: ["$IN(" ~ compile.text ~ ")/leaf.o", "-t", "2"], cwd: "t1")),
        null, defaultWeight(ActionKind.test));
    const layout = RunLayout("/w", "/run");
    const nodes = executionNodes(g, layout, [EnvEntry("PATH", "/bin")]);
    const c = nodes[0].action.match!((ref const ProcessAction p) => p, (_) => ProcessAction.init);
    assert(c.argv == ["ldc2", "--ffile-prefix-map=/w=.", "-of=/run/out/compile/r.leaf/library/ldc/abc/leaf.o"],
        text(c.argv));
    assert(c.completeEnvironment && c.envDelta.canFind(EnvEntry("PATH", ""))
        && c.envDelta.canFind(EnvEntry("SOURCE_DATE_EPOCH", sourceDateEpoch)) && c.cwd == "/w");
    const t = nodes[1].action.match!((ref const ProcessAction p) => p, (_) => ProcessAction.init);
    assert(t.argv[0] == "/run/out/compile/r.leaf/library/ldc/abc/leaf.o" && t.cwd == "/w/t1");
    assert(t.envDelta == [EnvEntry("PATH", "/bin")]);
}

/// The test root lists each module by its declared name, or by its path.
@("build_graph.execute.testRootModule")
@safe unittest
{
    assert(moduleNameOf("source/a/b.d", "/// doc\nmodule a.b ;\n", ["source"]) == "a.b");
    assert(moduleNameOf("source/a/c.d", "void f() {}\n", ["source"]) == "a.c");
    const m = testRootModule(["a.b", "a.c"]);
    assert(m.canFind("static import a.b;\nstatic import a.c;\n"));
    assert(m.canFind("alias allModules = TypeTuple!(\n    a.b,\n    a.c\n);"));
}
