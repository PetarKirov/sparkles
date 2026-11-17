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

With a cache directory ($(LREF RunLayout.cache)), the driver uses the store
(§6, $(REF Store, sparkles,build_primitives,plan,store)) beneath it: when the
executor admits an action, its declared key is computed (BGK1), each
`$IN(<id>)` standing for the digest of that producer's outputs, and a
published result is looked up, through a compile's manifests (BGK3). A hit
leaves the action's output directory a link to the result and runs nothing; a
successful miss is published, a compile with the manifest the fork's
dependency output gives (BGK2). Tests are not reused. Without a cache, every run builds what it plans.
*/
module sparkles.build_graph.execute;

import std.algorithm.searching : canFind, startsWith;
import std.array : join, replace;
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
    /// The cache directory holding the store's `build/` beside `runs/`,
    /// absolute; `runDirectory` must lie beneath it. Empty runs without a
    /// store (§6).
    string cache;
    /// The toolchain identity (§8), which every declared key covers (BGK1).
    string toolchain;
    /// BGS9: the determinism check. Every keyed action runs, lookup
    /// bypassed, publishing nothing; its outputs are compared with the
    /// result its key leads to, and a result that differs is removed.
    bool check;

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
        // Temporary files go to the action's own directory: the C driver
        // an LDC link runs writes them, and `/tmp` is no action's (D39).
        EnvEntry("TMPDIR", "$MEASURE"),
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
                // A typed generator states its environment over a build's (§7).
                q.envDelta = build ? plannedEnvironment(null, layout, id)
                    : a.kind == ActionKind.generate && p.envDelta.length ? plannedEnvironment(p.envDelta, layout, id)
                    : declared.dup;
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

// A build's environment with `planned`'s entries, expanded, in their place.
private EnvEntry[] plannedEnvironment(const EnvEntry[] planned, const RunLayout layout, TaskId self) @safe
{
    EnvEntry[] env;
    foreach (e; buildEnvironment())
        if (!planned.canFind!(p => p.name == e.name))
            env ~= EnvEntry(e.name, expand(e.value, layout, self));
    foreach (e; planned)
        env ~= EnvEntry(e.name, expand(e.value, layout, self));
    return env;
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
import sparkles.build_graph.store : Manifest, ManifestEntry, OutputRecord, ResultRecord, Store,
    preimageDifferences, differences,
    cacheDirTag, declaredKeyOf, formatVersion, hexOf, layoutVersion, parseHex, readAll, readBytes, resultKey,
    statPath, resolvedPath;

// A producer a digest record served, and what its publication needs (BGS5).
private struct Recorded
{
    string declared;
    string preimage;
}

/// What a run did with each kind of action: reused it from the store, or
/// executed it.
struct RunStats
{
    size_t[string] reused;   /// by kind
    size_t[string] executed; /// by kind
    size_t[string] misses;   /// by class (BGS8): `declared`, `manifest`, `evicted`

    string[] futureTimes; /// files whose modification time is later than the clock (BGK5)

    void future(string path) @safe pure nothrow
    {
        foreach (p; futureTimes)
            if (p == path)
                return;
        futureTimes ~= path;
    }

    void miss(string class_) @safe pure nothrow
    {
        if (auto n = class_ in misses)
            ++*n;
        else
            misses[class_] = 1;
    }

    void count(string kind, bool hit) @safe pure nothrow
    {
        auto into = hit ? &reused : &executed;
        if (auto n = kind in *into)
            ++*n;
        else
            (*into)[kind] = 1;
    }

    /// `compile 3 executed, 12 reused; link …`, by kind in order.
    string summary() const @safe
    {
        import std.algorithm.sorting : sort;

        bool[string] kinds;
        foreach (k, _; reused)
            kinds[k] = true;
        foreach (k, _; executed)
            kinds[k] = true;
        string s;
        foreach (k; kinds.keys.sort)
            s ~= (s.length ? "; " : "") ~ k ~ " " ~ text(executed.get(k, 0)) ~ " executed, "
                ~ text(reused.get(k, 0)) ~ " reused";
        foreach (c; misses.keys.sort)
            s ~= "; " ~ text(misses[c]) ~ " " ~ c ~ " misses";
        if (futureTimes.length)
            s ~= "; " ~ text(futureTimes.length) ~ " files dated in the future, rehashed: " ~ futureTimes.join(", ");
        return s;
    }
}

// This process's lease name: its id and start time, so a reused id names
// another holder (BGS4).
private string leaseHolder() @safe
{
    import core.sys.posix.unistd : getpid;
    import std.datetime.systime : Clock;

    return text((() @trusted => getpid())(), "-", Clock.currStdTime);
}

/// Whether a lease holder, `<pid>-<start>`, still runs (BGS4).
bool holderRuns(string holder) @trusted nothrow
{
    import core.sys.posix.signal : kill;

    int pid;
    foreach (c; holder)
    {
        if (c == '-')
            break;
        if (c < '0' || c > '9')
            return false;
        pid = pid * 10 + (c - '0');
    }
    return pid > 0 && kill(pid, 0) == 0;
}

private string parentOf(string path) @safe pure nothrow @nogc
{
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/')
        --slash;
    return slash > 1 ? path[0 .. slash - 1] : "/";
}

private string baseNameOf(string path) @safe pure nothrow @nogc
{
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/')
        --slash;
    return path[slash .. $];
}

/**
The prerequisites of the make rules in `text`, as `-makedeps` writes them:
after each target's `:`, separated by whitespace and escaped line breaks,
with spaces and `#` escaped by a backslash and `$` doubled.
*/
string[] makeRulePrerequisites(scope const(char)[] text) @safe pure
{
    string[] result;
    string current;
    bool inRule;
    void flush()
    {
        if (current.length)
            result ~= current;
        current = null;
    }
    for (size_t i = 0; i < text.length; ++i)
    {
        const c = text[i];
        const next = i + 1 < text.length ? text[i + 1] : '\0';
        if (!inRule)
        {
            if (c == '\\' && next != '\0')
                ++i;
            else if (c == ':' && (next == ' ' || next == '\n' || next == '\0' || next == '\\'))
                inRule = true;
            continue;
        }
        if (c == '\\' && (next == ' ' || next == '#'))
        {
            current ~= next;
            ++i;
        }
        else if (c == '\\' && (next == '\n' || next == '\r'))
        {
            flush();
            ++i;
        }
        else if (c == '$' && next == '$')
        {
            current ~= '$';
            ++i;
        }
        else if (c == '\n')
        {
            flush();
            inRule = false;
        }
        else if (c == ' ' || c == '\t' || c == '\r')
            flush();
        else
            current ~= c;
    }
    flush();
    return result;
}

/// `-makedeps` rules read back, escapes undone.
@("build_graph.execute.makeRulePrerequisites")
@safe pure unittest
{
    assert(makeRulePrerequisites("x.o: \\\n  a/m.d \\\n  b/with\\ space.d \\\n  c/$$d.d\n")
        == ["a/m.d", "b/with space.d", "c/$d.d"]);
    assert(makeRulePrerequisites("x.o:\n") is null);
}

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
    private Dir!(BlockingVfs, Rights.all) cacheRoot; // with a store: holds `build/` and the run
    private Dir!(BlockingVfs, Rights.all) run_;
    private Dir!(BlockingVfs, Rights.readOnly) worktree;
    private Dir!(BlockingVfs, Rights.readOnly) system; // absolute paths a manifest names
    private Store!(Dir!(BlockingVfs, Rights.all)) store;
    private bool stored;
    private const(Action)*[string] planned;
    private string[string] outputsDigestOf; // by task id: what a consumer's key holds (BGK1)
    private ubyte[32][string] digests;      // file digests read this run, by manifest path
    private Recorded[string] recorded;      // producers only a digest record served (BGS5)
    private ProcessAction[string] concreteProcess; // each process action as it runs
    private bool clocked;      // whether the store's probe read its file system's clock (BGK5)
    private long clockNs;
    private ulong clockDevice;
    private string failure;

    /// What the run did, by action kind: reused from the store, or executed.
    RunStats stats;

    /**
    A driver for `nodes` in `layout`, which `g` planned. Without a cache the
    run directory and the worktree are the two roots it opens (BGF2): the
    run directory with every right and the worktree read-only. With one, the
    cache directory, which holds the store and the run directory, takes the
    run directory's place, so a publication renames within one root (BGS2),
    and the manifests' absolute paths are read through a read-only root.
    */
    this(RunLayout layout, const TaskNode[] nodes, const(ActionGraph)* g = null) @safe
    {
        import core.lifetime : move;
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, SymlinkPolicy;

        this.layout = layout;
        vfs = new BlockingVfs;
        if (g !is null)
            foreach (ref a; g.actions)
                planned[a.id.text] = &a;
        foreach (ref n; nodes)
            n.action.match!(
                (ref const ProcessAction p) { concreteProcess[n.id.text] = ProcessAction(p.argv.dup, p.envDelta.dup, p.cwd); },
                (ref const _) {});
        if (layout.cache.length && layout.runDirectory.startsWith(layout.cache ~ "/"))
        {
            // A run reads its producers' outputs through the links into the
            // store that publication leaves, all beneath the cache.
            auto top = openRoot!(Rights.all)(vfs, layout.cache, ambientAuthority(),
                ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
            if (top.hasError)
                failure = "cannot open the cache directory " ~ layout.cache;
            else
            {
                cacheRoot = move(top.value);
                auto made = cacheRoot.walkAll(layout.runDirectory[layout.cache.length + 1 .. $]);
                auto build = cacheRoot.walkAll("build");
                auto runs = cacheRoot.walk("runs");
                if (!runs.hasError)
                    cast(void) runs.value.writeFileAtomic("CACHEDIR.TAG", cacheDirTag);
                if (made.hasError || build.hasError)
                    failure = "cannot open the run directory " ~ layout.runDirectory;
                else
                {
                    run_ = move(made.value);
                    stored = (() @trusted => Store!(Dir!(BlockingVfs, Rights.all)).open(build.value,
                        leaseHolder(), store))();
                    if (stored)
                        clocked = store.probeClock(clockNs, clockDevice);
                }
            }
            auto root = openRoot!(Rights.readOnly)(vfs, "/", ambientAuthority(),
                ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject, crossMounts: true));
            if (!root.hasError)
                system = move(root.value);
        }
        else
        {
            auto made = openRoot!(Rights.all)(vfs, layout.runDirectory, ambientAuthority());
            if (made.hasError)
                failure = "cannot open the run directory " ~ layout.runDirectory;
            else
                run_ = move(made.value);
        }
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

    /// Whether results are looked up and published (§6).
    bool hasStore() const @safe pure nothrow @nogc => stored;

    /// Ends the leases the run holds (BGS4).
    void finish()
    {
        if (stored)
            store.releaseLeases();
    }

    /**
    Runs `ctx`'s action (the executor's entry point). With a store, a
    keyed action is looked up first, when the executor admits it (BGS4): a
    hit links its output directory to the published result and runs
    nothing; a miss runs, and a success is published.
    */
    TaskOutcome run(ref TaskContext!Sched ctx)
    {
        import sparkles.build_primitives.task.model : FailureReason, Failed, OutputStream, Succeeded;

        if (failure.length)
            return TaskOutcome(Failed(FailureReason.contract));
        const id = ctx.node.id;
        auto a = id.text in planned;
        const kind = a !is null ? text((*a).kind) : "action";
        string declared, preimage;
        if (stored && a !is null && reusable(**a))
            if (declaredPreimage(**a, preimage))
                declared = declaredKeyOf(preimage);
        const(ResultRecord)* checked;
        if (declared.length && layout.check)
            checked = lookup(**a, declared);
        else if (declared.length)
        {
            if (auto hit = lookup(**a, declared))
                if (adopt(id, *hit))
                {
                    stats.count(kind, true);
                    return TaskOutcome(Succeeded());
                }
            // BGS5: a result only its digest record holds serves its
            // consumers' keys; its bytes are made when one that misses needs
            // them.
            if (auto r = recordedResult(**a, declared))
            {
                recorded[id.text] = Recorded(declared, preimage);
                outputsDigestOf[id.text] = r.outputsDigest;
                stats.count(kind, true);
                stats.miss("record-served");
                ctx.output(OutputStream.stderr, "served from its digest record (BGS5)");
                return TaskOutcome(Succeeded());
            }
            // BGS8: every miss is classified and explained.
            const miss = explainMiss(**a, declared, preimage);
            stats.miss(miss[0]);
            ctx.output(OutputStream.stderr, "miss (" ~ miss[0] ~ "): " ~ miss[1]);
        }
        if (stored && a !is null)
            if (const why = materializeInputs(**a, (string m) => ctx.output(OutputStream.stderr, m)))
            {
                ctx.output(OutputStream.stderr, why);
                return TaskOutcome(Failed(FailureReason.contract));
            }
        if (!makeDirectories(id))
            return TaskOutcome(Failed(FailureReason.contract));
        auto outcome = process.run(ctx);
        stats.count(kind, false);
        const succeeded = outcome.match!((ref Succeeded _) => true, (ref _) => false);
        if (!succeeded || !stored)
            return outcome;

        ResultRecord record;
        record.task = id.text;
        record.toolchain = layout.toolchain;
        record.declaredKey = declared;
        record.outputs = outputsOf(id);
        outputsDigestOf[id.text] = record.outputsDigest;
        if (layout.check)
        {
            // Cold and unshared: compared, never published (BGS9).
            if (checked !is null)
            {
                const differing = differences(*checked, record);
                if (differing.length)
                {
                    stats.miss("nondeterministic");
                    ctx.output(OutputStream.stderr, "nondeterministic: result " ~ checked.resultKey
                        ~ " differs in " ~ differing ~ "; removed");
                    string[] held;
                    const key = checked.resultKey;
                    cast(void) store.remove((ref const ResultRecord r) => r.resultKey == key,
                        (string h) => holderRuns(h), held);
                }
                else
                    stats.miss("deterministic");
            }
            return outcome;
        }
        if (!declared.length)
            return outcome;
        if (!publishRun(id, **a, declared, preimage, record, (string m) => ctx.output(OutputStream.stderr, m)))
            return TaskOutcome(Failed(FailureReason.contract));
        return outcome;
    }

    /*
    Publishes the outputs `id` just made under its declared key, a compile's
    through its manifest. False only when BGK8 fails the compile.
    */
    private bool publishRun(TaskId id, ref const Action a, string declared, string preimage,
        ref ResultRecord record, scope void delegate(string) note)
    {
        Manifest manifest;
        const hasManifest = withManifest(a);
        if (a.kind == ActionKind.compile && !hasManifest)
            note("conservatively keyed: no dependency output (BGK6)");
        if (hasManifest)
        {
            string why;
            if (!readManifest(id, manifest, why))
            {
                note("not published: " ~ why);
                return true;
            }
            // BGK8: a read outside the declared roots fails the compile.
            if (const outside = outsideRoots(a, manifest))
            {
                note("read outside its declared roots: " ~ outside);
                return false;
            }
            record.resultKey = resultKey(declared, manifest);
        }
        else
            record.resultKey = declared;
        const name = layout.outOf(id);
        auto parent = run_.walk(relativeToRun(parentOf(name)));
        if (parent.hasError)
            return true;
        const published = store.publish(parent.value, baseNameOf(name), record, linkTo(name));
        if (store.note.length)
            note(store.note);
        if (published !is null)
        {
            store.recordPreimage(id.text, preimage);
            if (hasManifest)
                store.useManifest(declared, manifest);
            outputsDigestOf[id.text] = published.outputsDigest;
        }
        return true;
    }

    // The digest record `a`'s declared key leads to, for a process action
    // whose result was evicted (BGS5).
    private const(ResultRecord)* recordedResult(ref const Action a, string declared)
    {
        const isProcess = a.action.match!((ref const ProcessAction _) => true, (ref const _) => false);
        if (!isProcess)
            return null;
        if (!withManifest(a))
            return store.record(declared);
        foreach (ref m; store.manifests(declared))
            if (holds(m))
                if (auto r = store.record(resultKey(declared, m)))
                    return r;
        return null;
    }

    /*
    BGS5: makes the outputs of each producer `a` consumes that only a digest
    record served, before `a` runs: each runs now, from its concrete command,
    after its own such producers, and is published. A producer whose outputs
    differ from its record is reported nondeterministic. Returns why one
    could not be made, or null.
    */
    private string materializeInputs(ref const Action a, scope void delegate(string) note)
    {
        import std.process : Config, execute;

        foreach (producer; producersOf(a))
        {
            auto r = producer in recorded;
            if (r is null)
                continue;
            const rec = *r;
            recorded.remove(producer);
            auto pa = producer in planned;
            auto concrete = producer in concreteProcess;
            if (pa is null || concrete is null)
                return "cannot make " ~ producer ~ ": it is not planned";
            if (const why = materializeInputs(**pa, note))
                return why;
            const id = (**pa).id;
            if (!makeDirectories(id))
                return "cannot make " ~ producer ~ "'s directories";
            string[string] env;
            foreach (e; concrete.envDelta)
                env[e.name] = e.value;
            const ran = (() @trusted => execute(concrete.argv, env, Config.newEnv, size_t.max,
                concrete.cwd))();
            cast(void) run_.writeFileAtomic(relativeToRun(layout.outOf(id)) ~ "/output.log", ran.output);
            if (ran.status != 0)
                return "cannot make " ~ producer ~ ": it exited " ~ text(ran.status);
            stats.count(text((**pa).kind), false);
            ResultRecord record;
            record.task = producer;
            record.toolchain = layout.toolchain;
            record.declaredKey = rec.declared;
            record.outputs = outputsOf(id);
            const digest = record.outputsDigest;
            if (digest != outputsDigestOf.get(producer, digest))
                note("nondeterministic: " ~ producer ~ " differs from its digest record (BGS5)");
            outputsDigestOf[producer] = digest;
            if (!publishRun(id, **pa, rec.declared, rec.preimage, record, note))
                return producer ~ " read outside its declared roots";
        }
        return null;
    }

    // The task ids `a`'s arguments name as `$IN(<id>)`.
    private static string[] producersOf(ref const Action a) @safe
    {
        string[] ids;
        void scan(string arg)
        {
            size_t i;
            while (i < arg.length)
            {
                if (arg[i .. $].startsWith("$IN("))
                {
                    size_t close = i + 4;
                    while (close < arg.length && arg[close] != ')')
                        ++close;
                    const id = arg[i + 4 .. close];
                    if (!ids.canFind(id))
                        ids ~= id;
                    i = close + 1;
                }
                else
                    ++i;
            }
        }
        a.action.match!(
            (ref const ProcessAction p) { foreach (x; p.argv) scan(x); foreach (e; p.envDelta) scan(e.value); },
            (ref const InProcessAction i) { foreach (x; i.arguments) scan(x); },
            (ref const _) {});
        return ids;
    }

    // Whether `a`'s result may be reused: a test's never is (BGX2, E3).
    private static bool reusable(ref const Action a) @safe pure nothrow
    {
        if (a.kind == ActionKind.test)
            return false;
        return true;
    }

    // Whether `a` is a compile with the fork's dependency output, keyed by
    // its manifest (BGK2, BGK3); any other compile is keyed conservatively
    // (BGK6).
    private static bool withManifest(ref const Action a) @safe pure nothrow
        => a.kind == ActionKind.compile && a.action.match!(
            (ref const ProcessAction p) => p.argv.canFind!(x => x.startsWith("--makedeps-digests=")),
            (ref const _) => false);

    /*
    BGK1: the declared key's preimage, one component per line: the format
    version, the kind, the argument vector with each `$IN(<id>)` naming the
    digest of that producer's outputs, the declared environment, the working
    directory, and the content digests of the worktree files the arguments
    name. False when a producer's outputs are unknown.
    */
    private bool declaredPreimage(ref const Action a, out string preimage)
    {
        string s = "format " ~ formatVersion.text ~ "\nkind " ~ text(a.kind) ~ "\ntoolchain " ~ layout.toolchain ~ "\n";
        bool known = true;
        string normalized(string arg)
        {
            string result;
            size_t i;
            while (i < arg.length)
            {
                if (arg[i .. $].startsWith("$IN("))
                {
                    size_t close = i + 4;
                    while (close < arg.length && arg[close] != ')')
                        ++close;
                    if (auto d = arg[i + 4 .. close] in outputsDigestOf)
                        result ~= "$IN(" ~ *d ~ ")";
                    else
                        known = false;
                    i = close + 1;
                }
                else
                    result ~= arg[i++];
            }
            return result;
        }
        void input(string path)
        {
            ubyte[32] d;
            if (digestOf(path, d))
                s ~= "input " ~ hexOf(d) ~ " " ~ path ~ "\n";
        }
        a.action.match!(
            (ref const ProcessAction p) {
                foreach (arg; p.argv)
                {
                    s ~= "arg " ~ normalized(arg) ~ "\n";
                    if (arg.length && arg[0] != '-' && arg[0] != '$' && arg[0] != '/' && arg.canFind('/'))
                        input(arg);
                }
                // BGK2: the C preprocessor reports no failed lookup, so a compile
                // with ImportC sources keys on every file under its C include
                // roots and its C sources' own directories (as BGK6 does).
                if (a.kind == ActionKind.compile)
                    foreach (dir; cRoots(p.argv))
                        s ~= "c-root " ~ dir ~ " " ~ treeDigest(dir) ~ "\n";
                // BGK9: a link keys on where each library it links resolved
                // along its `-L` search order, and on the candidates absent
                // before it, so a library created earlier on the path changes it.
                if (a.kind == ActionKind.link)
                    foreach (line; librarySearch(p.argv))
                        s ~= line ~ "\n";
                // BGK6: a compile without dependency output keys on every file
                // beneath every worktree root it searches.
                if (a.kind == ActionKind.compile && !withManifest(a))
                    foreach (arg; p.argv)
                        foreach (prefix; ["-I=", "-J="])
                            if (arg.startsWith(prefix) && !arg[prefix.length .. $].startsWith("/")
                                    && !arg[prefix.length .. $].startsWith("$"))
                                s ~= "root " ~ arg[prefix.length .. $] ~ " " ~ treeDigest(arg[prefix.length .. $]) ~ "\n";
                // BGG5: the shader compiler resolves imports and reports no
                // manifest, so it keys on every file beneath its device
                // configuration's import roots (BGK6).
                foreach (dir; shaderRoots(p.argv))
                    s ~= "shader-root " ~ dir ~ " " ~ treeDigest(dir) ~ "\n";
                const env = a.kind == ActionKind.generate && p.envDelta.length ? p.envDelta : buildEnvironment();
                foreach (e; env)
                    s ~= "env " ~ e.name ~ "=" ~ e.value ~ "\n";
                s ~= "cwd " ~ p.cwd ~ "\n";
            },
            (ref const InProcessAction i) {
                s ~= "handler " ~ i.handler ~ "\n";
                foreach (arg; i.arguments)
                    s ~= "arg " ~ normalized(arg) ~ "\n";
                // The test-root module reads the tested sources it names.
                if (i.handler == "generate:test-root-module" && i.arguments.length > 2)
                {
                    const dir = i.arguments[0];
                    size_t at = 2;
                    while (at < i.arguments.length && i.arguments[at] != "--")
                        ++at;
                    foreach (source; i.arguments[at + 1 .. $])
                        input(dir.length && dir != "." ? dir ~ "/" ~ source : source);
                }
            },
            (ref const InertAction _) {});
        preimage = s;
        return known;
    }

    /*
    BGS8: why `a` missed. `declared` when no manifest list exists for its
    declared key (or, for an action without one, no result), naming each
    component that differs from the preimage its task last published;
    `manifest` when a list exists but no manifest matches, naming the most
    recently used one's first file whose digest differs, or its first absent
    candidate that now exists; `evicted` when a manifest matches but its
    result is gone.
    */
    private string[2] explainMiss(ref const Action a, string declared, string preimage)
    {
        string declaredMiss()
        {
            const older = store.preimage(a.id.text);
            if (older is null)
                return "no preimage is recorded for the task";
            const differing = preimageDifferences(older, preimage);
            return differing.length ? "differs in " ~ differing : "the same preimage, published under another key";
        }
        if (!withManifest(a))
            return ["declared", declaredMiss()];
        const list = store.manifests(declared);
        if (!list.length)
            return ["declared", declaredMiss()];
        foreach (ref m; list)
            if (holds(m))
                return ["evicted", "a manifest matches, and its result " ~ resultKey(declared, m) ~ " is gone"];
        foreach (ref f; list[0].files)
        {
            if (f.path.startsWith("/nix/store/"))
                continue;
            ubyte[32] d;
            if (!digestOf(f.path, d))
                return ["manifest", f.path ~ " is gone"];
            if (d != f.digest)
                return ["manifest", f.path ~ " changed"];
        }
        foreach (path; list[0].absent)
            if (!path.startsWith("/nix/store/") && present(path))
                return ["manifest", path ~ " appeared"];
        return ["manifest", "no manifest matches"];
    }

    /*
    BGK9: for each `-L-l<name>` a link passes, the first of `lib<name>.so`
    and `lib<name>.a` along its `-L-L<dir>` directories, in order, as
    `library <name> <path> after <n> absent`, or `library <name> unresolved`
    when none holds it (the toolchain's own directories, which its identity
    covers, then serve it).
    */
    private string[] librarySearch(const string[] argv)
    {
        string[] dirs, names, lines;
        foreach (arg; argv)
            if (arg.startsWith("-L-L") && arg.length > 4)
                dirs ~= arg[4 .. $];
            else if (arg.startsWith("-L-l") && arg.length > 4)
                names ~= arg[4 .. $];
        foreach (name; names)
        {
            size_t absentBefore;
            string found;
            foreach (dir; dirs)
            {
                foreach (file; ["lib" ~ name ~ ".so", "lib" ~ name ~ ".a"])
                {
                    const path = dir ~ "/" ~ file;
                    if (present(path))
                    {
                        found = path;
                        break;
                    }
                    ++absentBefore;
                }
                if (found.length)
                    break;
            }
            lines ~= found.length ? text("library ", name, " ", found, " after ", absentBefore, " absent")
                : "library " ~ name ~ " unresolved";
        }
        return lines;
    }

    // The worktree import roots of the device configuration a shader
    // compiler's `--described=$IN(<id>)/device.json` names, from the
    // description its producer writes.
    private string[] shaderRoots(const string[] argv)
    {
        import std.json : JSONException, JSONType, parseJSON;

        string[] dirs;
        foreach (arg; argv)
        {
            enum prefix = "--described=$IN(";
            if (!arg.startsWith(prefix))
                continue;
            size_t close = prefix.length;
            while (close < arg.length && arg[close] != ')')
                ++close;
            auto producer = arg[prefix.length .. close] in planned;
            if (producer is null)
                continue;
            string described;
            (**producer).action.match!(
                (ref const InProcessAction i) { if (i.arguments.length == 2) described = i.arguments[1]; },
                (ref const _) {});
            try
            {
                foreach (t; parseJSON(described)["targets"].array)
                    foreach (p; t["buildSettings"]["importPaths"].array)
                        if (p.type == JSONType.string && p.str.startsWith("$ROOT/"))
                        {
                            auto d = p.str["$ROOT/".length .. $];
                            while (d.length && d[$ - 1] == '/')
                                d = d[0 .. $ - 1];
                            if (!dirs.canFind(d))
                                dirs ~= d;
                        }
            }
            catch (JSONException)
                continue;
        }
        return dirs;
    }

    // The worktree directories a compile's C preprocessor searches: each C
    // source's own and each C include root (`-P-I`) in the worktree.
    private static string[] cRoots(const string[] argv) @safe pure
    {
        string[] dirs;
        void add(string d)
        {
            if (d.length && !d.startsWith("/") && !d.startsWith("$") && !dirs.canFind(d))
                dirs ~= d;
        }
        foreach (arg; argv)
        {
            if (arg.startsWith("-P-I"))
                add(arg[4 .. $]);
            else if (arg.length > 2 && arg[0] != '-' && (arg[$ - 2 .. $] == ".c" || arg[$ - 2 .. $] == ".i"))
                add(parentOf(arg));
        }
        // LDC hands the preprocessor its D import roots too.
        if (dirs.length)
            foreach (arg; argv)
                if (arg.startsWith("-I="))
                    add(arg[3 .. $]);
        return dirs;
    }

    // The digest of every regular file beneath the worktree directory `dir`,
    // by path and content, in path order (BGK6's reading of a root).
    private string treeDigest(string dir)
    {
        import std.algorithm.sorting : sort;
        import sparkles.base.hash.blake3 : blake3;
        import sparkles.base.vfs.types : EntryKind;

        string[] lines;
        void walk(string path)
        {
            auto d = worktree.walk(path);
            if (d.hasError)
                return;
            auto listing = d.value.list();
            if (listing.hasError)
                return;
            string[] names;
            while (true)
            {
                auto more = listing.value.next();
                if (more.hasError || !more.value)
                    break;
                names ~= listing.value.front.name.idup;
            }
            foreach (n; names)
            {
                const child = path ~ "/" ~ n;
                auto st = d.value.statAt(n);
                if (st.hasError)
                    continue;
                if (st.value.kind == EntryKind.directory)
                    walk(child);
                else if (st.value.kind == EntryKind.regular)
                {
                    ubyte[32] digest;
                    if (digestOf(child, digest))
                        lines ~= child ~ " " ~ hexOf(digest);
                }
            }
        }
        walk(dir);
        return hexOf(blake3(lines.sort.release.join("\n")));
    }

    // The result `a`'s declared key leads to, if the store holds one: for a
    // compile, through the most recently used manifest whose files hold the
    // digests it records and whose absent candidates are still absent (BGK3).
    private const(ResultRecord)* lookup(ref const Action a, string declared)
    {
        if (!withManifest(a))
            return store.find(declared);
        foreach (ref m; store.manifests(declared))
            if (holds(m))
                if (auto r = store.find(resultKey(declared, m)))
                {
                    store.useManifest(declared, m);
                    return r;
                }
        return null;
    }

    private bool holds(const ref Manifest m)
    {
        foreach (ref f; m.files)
        {
            if (f.path.startsWith("/nix/store/"))
                continue; // a store path's content is its name's
            ubyte[32] d;
            if (!digestOf(f.path, d) || d != f.digest)
                return false;
        }
        foreach (path; m.absent)
            if (!path.startsWith("/nix/store/") && present(path))
                return false;
        return true;
    }

    // Links `id`'s output directory to a published result and takes its
    // outputs' digest for the consumers' keys.
    private bool adopt(TaskId id, const ref ResultRecord r)
    {
        const name = layout.outOf(id);
        auto parent = run_.walkAll(relativeToRun(parentOf(name)));
        if (parent.hasError || run_.walkAll(relativeToRun(layout.measureOf(id))).hasError)
            return false;
        if (parent.value.symlinkAt(baseNameOf(name), linkTo(name).replace("{}", r.resultKey)).hasError)
            return false;
        outputsDigestOf[id.text] = r.outputsDigest;
        return true;
    }

    // The regular files beneath `id`'s output directory, its `output.log`
    // aside, sorted by path.
    private OutputRecord[] outputsOf(TaskId id)
    {
        import std.algorithm.sorting : sort;
        import sparkles.base.hash.blake3 : blake3;
        import sparkles.base.vfs.types : EntryKind;

        OutputRecord[] records;
        void walk(D)(ref D dir, string prefix)
        {
            auto listing = dir.list();
            if (listing.hasError)
                return;
            string[] files, dirs;
            while (true)
            {
                auto more = listing.value.next();
                if (more.hasError || !more.value)
                    break;
                const e = listing.value.front;
                const n = e.name.idup;
                auto st = dir.statAt(n);
                if (st.hasError)
                    continue;
                if (st.value.kind == EntryKind.directory)
                    dirs ~= n;
                else if (st.value.kind == EntryKind.regular)
                {
                    const path = prefix ~ n;
                    if (path == "output.log")
                        continue;
                    ubyte[] bytes;
                    if (readBytes(dir, n, bytes))
                        records ~= OutputRecord(path, bytes.length, st.value.executable, blake3(bytes));
                }
            }
            foreach (d; dirs)
            {
                auto sub = dir.walk(d);
                if (!sub.hasError)
                    walk(sub.value, prefix ~ d ~ "/");
            }
        }
        auto out_ = run_.walk(relativeToRun(layout.outOf(id)));
        if (!out_.hasError)
            walk(out_.value, "");
        return records.sort!((x, y) => x.path < y.path).release;
    }

    /*
    BGK8: the first file a compile's manifest lists that lies outside every
    root it declares, or null: its import, string import and C include
    roots and its sources, as its arguments name them; the outputs of the
    generators it reads (`$RUN/out/`); and the store, which holds the
    toolchain and the registry sources.
    */
    private string outsideRoots(ref const Action a, const ref Manifest m) const
    {
        string[] roots;
        a.action.match!(
            (ref const ProcessAction p) {
                foreach (arg; p.argv)
                {
                    foreach (prefix; ["-I=", "-J=", "-P-I"])
                        if (arg.startsWith(prefix))
                            roots ~= named(arg[prefix.length .. $]);
                    if (arg.length && arg[0] != '-' && arg[0] != '$' && arg.canFind('/'))
                        roots ~= arg;
                }
            },
            (ref const _) {});
        bool inside(string path)
        {
            if (path.startsWith("/nix/store/") || path.startsWith("$RUN/out/"))
                return true;
            foreach (r; roots)
            {
                const root = r.length > 1 && r[$ - 1] == '/' ? r[0 .. $ - 1] : r;
                if (path == root || path.startsWith(root ~ "/"))
                    return true;
            }
            return false;
        }
        foreach (ref f; m.files)
            if (!inside(f.path))
                return f.path;
        return null;
    }

    /*
    BGK2: a compile's manifest from the fork's dependency output, in its
    measurement directory: each file it read with the digest of what it
    read, and each absent candidate. A path in the run directory is named
    from it (`$RUN/…`), so the manifest is the same in every run. BGK7: a
    worktree file whose bytes now differ from what the compiler read
    conflicts, and the result is not published.
    */
    private bool readManifest(TaskId id, out Manifest m, out string why)
    {
        const measure = relativeToRun(layout.measureOf(id));
        string digestsText, absentText;
        if (!readAll(run_, measure ~ "/digests", digestsText) || !readAll(run_, measure ~ "/absent", absentText))
        {
            why = "the compiler wrote no dependency digests";
            return false;
        }
        import std.string : lineSplitter;

        foreach (line; digestsText.lineSplitter)
        {
            ManifestEntry e;
            if (line.length < 67 || !parseHex(line[0 .. 64], e.digest))
                continue;
            e.path = named(line[66 .. $].idup);
            if (!e.path.startsWith("/nix/store/"))
            {
                ubyte[32] now;
                if (!digestOf(e.path, now, fresh: true) || now != e.digest)
                {
                    why = "unstable input: " ~ e.path ~ " changed while the compiler ran";
                    return false;
                }
            }
            m.files ~= e;
        }
        foreach (path; makeRulePrerequisites(absentText))
            m.absent ~= named(path);
        return true;
    }

    // A compiler's path as a manifest names it: one in the run directory
    // from `$RUN/`, any other as given.
    private string named(string path) const @safe pure
    {
        if (path.startsWith(layout.runDirectory ~ "/"))
            return "$RUN/" ~ path[layout.runDirectory.length + 1 .. $];
        return path;
    }

    // The digest of the file a manifest path names, read once per run
    // unless `fresh`.
    private bool digestOf(string path, out ubyte[32] digest, bool fresh = false)
    {
        import sparkles.base.hash.blake3 : blake3;

        if (!fresh)
            if (auto d = path in digests)
            {
                digest = *d;
                return true;
            }
        // BGK5: a worktree file's digest is cached by its identity, on the
        // file system whose clock the store's probe read.
        import sparkles.base.vfs.types : Stat, StatMask;

        // A worktree path is read where its links lead, each resolved from the
        // root, so a link that climbs out of its directory reads (BGF3), and
        // the identity cached is its target's.
        string resolved = path;
        if (!path.startsWith("$RUN/") && !path.startsWith("/"))
            if (const r = resolvedPath(worktree, path))
                resolved = r;
        const cacheable = clocked && !path.startsWith("$RUN/") && !path.startsWith("/");
        Stat st;
        bool sameClock;
        if (cacheable)
        {
            auto s = statPath(worktree, resolved, cast(StatMask)(StatMask.mtime | StatMask.identity | StatMask.change));
            sameClock = !s.hasError && s.value.device == clockDevice;
            if (sameClock)
                st = s.value;
            if (sameClock)
            {
                if (st.mtimeNs > clockNs)
                    stats.future(path); // rehashed on every read, and reported
                else if (!fresh && store.cachedDigest(path, st, digest))
                {
                    digests[path] = digest;
                    return true;
                }
            }
        }
        ubyte[] bytes;
        bool read;
        if (path.startsWith("$RUN/"))
            // Through the cache's root: a producer's link climbs above the run.
            read = readBytes(cacheRoot, inCache(path[5 .. $]), bytes);
        else if (path.startsWith("/"))
            read = readBytes(system, path[1 .. $], bytes);
        else
            read = readBytes(worktree, resolved, bytes);
        if (!read)
            return false;
        digest = blake3(bytes);
        digests[path] = digest;
        if (sameClock && st.mtimeNs <= clockNs)
            store.cacheDigest(path, st, clockNs, digest);
        return true;
    }

    // Whether a manifest path names an entry that exists.
    private bool present(string path)
    {
        if (path.startsWith("$RUN/"))
            return !statPath(cacheRoot, inCache(path[5 .. $])).hasError;
        if (path.startsWith("/"))
            return !statPath(system, path[1 .. $]).hasError;
        return !statPath(worktree, path).hasError;
    }

    // A path relative to the run directory, as the cache's root names it.
    private string inCache(string path) const @safe pure
        => layout.runDirectory[layout.cache.length + 1 .. $] ~ "/" ~ path;

    private string relativeToRun(string path) const @safe pure
        => path.length > layout.runDirectory.length ? path[layout.runDirectory.length + 1 .. $] : "";

    // The relative link from the directory holding `name` to a result's
    // `out/`, `{}` standing for its key.
    private string linkTo(string name) const @safe pure
    {
        string up;
        foreach (c; parentOf(name)[layout.cache.length + 1 .. $])
            if (c == '/')
                up ~= "../";
        return up ~ "../build/v" ~ layoutVersion.text ~ "/results/{}/out";
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

    /*
    The failing tools a single-file generator finds on its `PATH` (§7): its
    arguments are the output directory, the failing program by absolute
    path, then the names, each an executable script whose interpreter line
    names the program, which so runs in its place (a VFS link takes only a
    relative target, VFO3).
    */
    TaskOutcome generateFailingTools(ref TaskContext!Sched ctx, const ref InProcessAction a) @system
    {
        import sparkles.build_primitives.task.model : FailureReason, Failed, OutputStream, Succeeded;
        import sparkles.base.vfs.types : Access, Disposition, OpenMode;

        if (a.arguments.length < 2)
        {
            ctx.output(OutputStream.stderr, "generate:failing-tools: too few arguments");
            return TaskOutcome(Failed(FailureReason.exitStatus, 1));
        }
        auto dir = run_.walkAll(a.arguments[0][layout.runDirectory.length + 1 .. $]);
        if (dir.hasError)
            return TaskOutcome(Failed(FailureReason.exitStatus, 1));
        enum script = OpenMode(Access.write, Disposition.createOrTruncate, executable: true);
        const line = "#!" ~ a.arguments[1] ~ "\n";
        foreach (name; a.arguments[2 .. $])
        {
            auto file = dir.value.openFile!script(name);
            if (file.hasError || file.value.write(cast(const(ubyte)[]) line).hasError)
            {
                ctx.output(OutputStream.stderr, "generate:failing-tools: cannot write " ~ name);
                return TaskOutcome(Failed(FailureReason.exitStatus, 1));
            }
        }
        return TaskOutcome(Succeeded());
    }

    /*
    A file the graph writes for a generator (§7): its arguments are the
    path, beneath the action's output directory, and the contents.
    */
    TaskOutcome generateFile(ref TaskContext!Sched ctx, const ref InProcessAction a) @system
    {
        import sparkles.build_primitives.task.model : FailureReason, Failed, OutputStream, Succeeded;

        TaskOutcome fail(string why)
        {
            ctx.output(OutputStream.stderr, "generate:file: " ~ why);
            return TaskOutcome(Failed(FailureReason.exitStatus, 1));
        }
        if (a.arguments.length != 2 || !a.arguments[0].startsWith(layout.runDirectory ~ "/"))
            return fail("takes a path in the run directory and the contents");
        const path = a.arguments[0][layout.runDirectory.length + 1 .. $];
        size_t slash = path.length;
        while (slash > 0 && path[slash - 1] != '/')
            --slash;
        auto dir = run_.walkAll(path[0 .. slash - 1]);
        if (dir.hasError || dir.value.writeFileAtomic(path[slash .. $], a.arguments[1]).hasError)
            return fail("cannot write " ~ a.arguments[0]);
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
    uint capacity, RunStats* stats = null)
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
    auto driver = new ActionDriver(layout, nodes, &g); // the generators' handlers hold its address
    if (driver.error.length)
        return RunResult(exitCode: 2);
    driver.processes.register("generate:test-root-module",
        (ref TaskContext!Sched ctx, const ref InProcessAction a) => driver.generateTestRoot(ctx, a));
    driver.processes.register("generate:file",
        (ref TaskContext!Sched ctx, const ref InProcessAction a) => driver.generateFile(ctx, a));
    driver.processes.register("generate:failing-tools",
        (ref TaskContext!Sched ctx, const ref InProcessAction a) => driver.generateFailingTools(ctx, a));
    auto reporter = PlainReporter!W(&writer, &graph, PlainOptions(timings: false));
    auto sink = new EventChannel;
    MonotonicClock clock;
    RunResult result;
    auto ran = s.run(() {
        cast(void) withScope!((ref sc) {
            sc.spawn(() { consumeEvents(s, *sink, reporter); });
            result = runGraph(s, clock, graph, *driver, *sink, ExecutorOptions(capacity: capacity));
            driver.finish();
            sink.close();
        })(s);
    });
    if (stats !is null)
        *stats = driver.stats;
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

/// The store's lifecycle on a real directory (oracle 17's first steps):
/// publication, the least recently used result evicted with its record
/// kept, verification finding a flipped byte, removal by task, and garbage
/// collection emptying `trash/`.
@("build_graph.execute.storeLifecycle")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Access, Disposition, OpenMode, Rights, ResolvePolicy, SymlinkPolicy,
        DotDotPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;
    import std.process : environment, thisProcessID;

    auto vfs = new BlockingVfs;
    auto tmp = openRoot!(Rights.all)(vfs, environment.get("TMPDIR", "/tmp"), ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
    assert(!tmp.hasError);
    const name = text("sparkles-store-lifecycle-", thisProcessID);
    cast(void) tmp.value.removeTree(name);
    auto top = tmp.value.walkAll(name);
    assert(!top.hasError);
    scope (exit)
        cast(void) tmp.value.removeTree(name);
    auto build = top.value.walkAll("build");
    Store!(typeof(build.value)) store;
    assert(Store!(typeof(build.value)).open(build.value, "1-1", store));

    import sparkles.base.hash.blake3 : blake3;

    // Two results of 100 bytes, published from a run directory beside the store.
    auto out_ = top.value.walkAll("runs/r/out");
    ResultRecord publishOne(string task, char fill)
    {
        auto dir = out_.value.walkAll(task);
        char[100] bytes = fill;
        assert(!dir.value.writeFileAtomic("f", bytes[]).hasError);
        ResultRecord r;
        r.task = task;
        r.resultKey = task ~ "-key";
        r.outputs = [OutputRecord("f", 100, false, blake3(cast(const(ubyte)[]) bytes[]))];
        assert(store.publish(out_.value, task, r, "../../../build/v1/results/{}/out") !is null, store.note);
        return r;
    }

    publishOne("a", 'a');
    publishOne("b", 'b');
    store.releaseLeases();
    store.lease("a-key"); // `a` is now the more recently used
    store.releaseLeases();
    assert(store.entries.length == 2);

    bool dead(string) => false;
    const report = store.evict(150, 1 << 20, &dead);
    assert(report.evicted == ["b-key"] && report.resultBytes == 100, text(report));
    assert(store.find("b-key") is null && store.find("a-key") !is null);
    store.releaseLeases();
    string record;
    assert(readAll(build.value, "v1/records/b-key", record) && record.canFind("output "));

    // A flipped byte, same size: only verification sees it (BGS6).
    auto published = build.value.walk("v1/results/a-key/out");
    char[100] flipped = 'a';
    flipped[50] = 'z';
    assert(!published.value.writeFileAtomic("f", flipped[]).hasError);
    assert(store.find("a-key") !is null);
    store.releaseLeases();
    assert(store.verify() == ["a-key"]);
    assert(store.find("a-key") is null);

    // Removal by task, then garbage collection.
    publishOne("c", 'c');
    store.releaseLeases();
    string[] held;
    assert(store.remove((ref const ResultRecord r) => r.task == "c", &dead, held) == ["c-key"] && !held.length);
    assert(store.collectGarbage(&dead) >= 2);
    assert(store.entries.length == 0);
}

/// BGK5: a cached digest is trusted only for the same identity tuple, and
/// only when the file's times are older than its recording minus two
/// seconds; a racily clean one is rehashed.
@("build_graph.execute.digestCache")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, Stat, SymlinkPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;
    import std.process : environment, thisProcessID;

    auto vfs = new BlockingVfs;
    auto tmp = openRoot!(Rights.all)(vfs, environment.get("TMPDIR", "/tmp"), ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
    const name = text("sparkles-digest-cache-", thisProcessID);
    auto top = tmp.value.walkAll(name);
    scope (exit)
        cast(void) tmp.value.removeTree(name);
    Store!(typeof(top.value)) store;
    assert(Store!(typeof(top.value)).open(top.value, "1-1", store));
    long now;
    ulong device;
    assert(store.probeClock(now, device) && now > 0);

    Stat st;
    st.device = device;
    st.inode = 7;
    st.size = 3;
    st.mtimeNs = 1_000_000_000_000;
    st.ctimeNs = 1_000_000_000_000;
    ubyte[32] digest = 9, got;
    store.cacheDigest("libs/a.d", st, st.mtimeNs + 1_000_000_000, digest); // racy: within two seconds
    assert(!store.cachedDigest("libs/a.d", st, got));
    store.cacheDigest("libs/a.d", st, st.mtimeNs + 3_000_000_000, digest);
    assert(store.cachedDigest("libs/a.d", st, got) && got == digest);
    auto touched = st;
    touched.ctimeNs += 1;
    assert(!store.cachedDigest("libs/a.d", touched, got)); // a hard link or chmod: rehash
    auto replaced = st;
    replaced.inode = 8;
    assert(!store.cachedDigest("libs/a.d", replaced, got));
    assert(!store.cachedDigest("libs/b.d", st, got));
}

/// BGR4 without Nix: a tree's NAR digest is the one `nix-hash` prints, and a
/// locked archive is fetched, checked against its flat SHA-256, unpacked
/// without its top directory and published; a wrong hash publishes nothing.
@("build_graph.execute.fetchLockedSources")
@system unittest
{
    import std.digest.sha : sha256Of;
    import std.zip : ArchiveMember, ZipArchive;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Access, Disposition, DotDotPolicy, OpenMode, ResolvePolicy, Rights,
        SymlinkPolicy;
    import sparkles.build_graph.fetch : Fetcher, fetchLockedSources, narDigest, nixBase32,
        parseNixBase32;
    import sparkles.build_primitives.resolve.registry : LockedPackage;
    import sparkles.event_horizon.sys : BlockingVfs;
    import std.process : environment, thisProcessID;

    auto vfs = new BlockingVfs;
    const tmpPath = environment.get("TMPDIR", "/tmp");
    auto tmp = openRoot!(Rights.all)(vfs, tmpPath, ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
    const name = text("sparkles-fetch-", thisProcessID);
    auto top = tmp.value.walkAll(name);
    scope (exit)
        cast(void) tmp.value.removeTree(name);

    // `nix-hash --type sha256 --base32` of this tree.
    auto fixture = top.value.walkAll("nar/sub");
    auto nar = top.value.walk("nar");
    assert(!nar.value.writeFileAtomic("a.txt", "hello\n").hasError);
    assert(!fixture.value.writeFileAtomic("b", "deep").hasError);
    {
        auto run = nar.value.openFile!(OpenMode(Access.write, Disposition.createNew, executable: true))("run.sh");
        assert(!run.value.write(cast(const(ubyte)[]) "#!/bin/sh\n").hasError);
    }
    assert(!nar.value.symlinkAt("link", "a.txt").hasError);
    ubyte[32] digest, expected;
    assert(narDigest(nar.value, digest));
    assert(parseNixBase32("17ykq8r6hx1xwcmvbbvfw2cyqp0ivybay79fdjvha4jwqw9griyi", expected));
    assert(digest == expected, nixBase32(digest));

    // A registry archive, served by a fetcher that writes it where asked.
    auto zip = new ZipArchive;
    foreach (member; [["pkg-1.0.0/dub.sdl", "name \"pkg\"\n"], ["pkg-1.0.0/source/pkg.d", "module pkg;\n"]])
    {
        auto m = new ArchiveMember;
        m.name = member[0];
        m.expandedData = cast(ubyte[]) member[1].dup;
        zip.addMember(m);
    }
    const archive = cast(ubyte[]) zip.build();
    auto sources = top.value.walkAll("sources");
    const sourcesPath = tmpPath ~ "/" ~ name ~ "/sources";
    auto fetcher = Fetcher(
        (string url, string destination) {
            assert(url == "https://code.dlang.org/packages/pkg/1.0.0.zip", url);
            return !sources.value.walk("staging").value.writeFileAtomic(
                destination[sourcesPath.length + "/staging/".length .. $], archive).hasError;
        },
        (string url, string commit, string destination) => false);
    auto wrong = [LockedPackage("pkg", "1.0.0", null, nixBase32(sha256Of("other")), "lock.json")];
    const refused = fetchLockedSources(wrong, sources.value, sourcesPath, fetcher);
    assert(refused.canFind("the lock pins"), refused);
    assert(statPath(sources.value, ".dub/packages/pkg/1.0.0/pkg").hasError);
    auto right = [LockedPackage("pkg", "1.0.0", null, nixBase32(sha256Of(archive)), "lock.json")];
    assert(fetchLockedSources(right, sources.value, sourcesPath, fetcher) is null);
    string text_;
    assert(readAll(sources.value, ".dub/packages/pkg/1.0.0/pkg/source/pkg.d", text_) && text_ == "module pkg;\n");
}

/// A link whose target climbs out of its own directory but not out of the
/// root resolves, component by component; one that leaves the root does not.
@("build_graph.execute.resolvedPath")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;
    import std.process : environment, thisProcessID;

    auto vfs = new BlockingVfs;
    auto tmp = openRoot!(Rights.all)(vfs, environment.get("TMPDIR", "/tmp"), ambientAuthority(),
        ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
    const name = text("sparkles-resolved-", thisProcessID);
    auto top = tmp.value.walkAll(name);
    scope (exit)
        cast(void) tmp.value.removeTree(name);
    auto a = top.value.walkAll("a");
    auto b = top.value.walkAll("b");
    assert(!a.value.writeFileAtomic("f", "x").hasError);
    assert(!b.value.symlinkAt("l", "../a/f").hasError);
    assert(!b.value.symlinkAt("dir", "../a").hasError);
    assert(!b.value.symlinkAt("out", "../../elsewhere").hasError);
    assert(resolvedPath(top.value, "b/l") == "a/f");
    assert(resolvedPath(top.value, "b/dir/f") == "a/f");
    assert(resolvedPath(top.value, "b/out") is null);
    string text_;
    assert(readAll(top.value, resolvedPath(top.value, "b/l"), text_) && text_ == "x");
}
