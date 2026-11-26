/++
`ci commits build-each`: build the chosen sub-packages at every commit of a range.

CI builds a pull request's $(I tip). A stacked series is merged by rebase, so
every commit in it lands on `main` and becomes a `git bisect` stop, and the
repository asks each one to build on its own ([Git hygiene](../../docs/guidelines/AGENTS.md#git-hygiene--atomic-commits)).
Nothing checked that. The gap is widest for the apps whose default configuration
is a GUI build: `dub test` compiles their `unittest` configuration and never the
one a user runs (the native window of `hue`, the gallery and the diagram board).
Before this mode, that loop was run by hand before every push. The documentation
site's WebAssembly modules are the same case: their default configuration is a
`wasm32-unknown-wasip1` reactor, which no native build or test compiles.

Every commit of the range is checked out in a scratch worktree of its own,
planned there, and run with the others as one graph against the shared store
(ci task-DAG CIC21). A commit compiles only the actions whose keys it
changes, and the commits build at once: an action predicted to share its key
with the previous commit's ($(LREF reuseEdges)) waits for that one and reuses
its result, and every other action starts as soon as its own commit allows.
Each WebAssembly module builds there for every host the toolchain table
lists it for ($(LREF unitsOf)). A package planning refuses builds with dub in
one more worktree, walked oldest first so each build is incremental on the
last, as tasks of the same run. Uncommitted changes are not part of any
commit and are not built.

This module is the planning half: what the range is, which packages, which
actions wait for which. The execution is `runBuildEachCommitMode`, in
`commands/maintenance.d`.
+/
module each_commit;

import std.algorithm : any, canFind, endsWith, map, startsWith;
import std.array : array;
import std.conv : text;
import std.path : baseName;
import std.string : indexOf, lineSplitter, strip;

import sparkles.build_graph.actions : ActionGraph;
import sparkles.build_primitives.task.action : InProcessAction, ProcessAction, TaskAction;
import sparkles.build_primitives.task.model : OutcomeKind, TaskEdge, TaskId;

/++
The packages built when `--packages` names none: the ones whose default
configuration `dub test` never compiles, which is exactly where a commit that
passes its tests can still fail to build.
+/
immutable string[] defaultEachCommitPackages = ["hue", "ui-gallery", "diagram",
    "text-wasm", "table-wasm", "wired-wasm", "dub-manifest-nix-wasm"];

/++
One build of a range's commits: a package, by its path and name, for a host
platform by its nixpkgs `config`, or for the build platform when `host` is
empty (build-graph BGH2).
+/
struct BuildUnit
{
    string path; /// the sub-package's directory (`libs/base/text-wasm`)
    string name; /// its name (`text-wasm`)
    string host; /// its host's `config`, or empty for the build platform

    /// How a report names it: `text-wasm (wasm32-unknown-wasip1)`, `hue`.
    string label() const @safe pure => host.length ? name ~ " (" ~ host ~ ")" : name;
}

/++
The units `packages` (sub-package paths) build as: each package the toolchain
table lists in `hostsOf` (its `packages`, the WebAssembly modules and their
previews) once per host, every other one for the build platform.
+/
BuildUnit[] unitsOf(in string[] packages, in string[][string] hostsOf) @safe pure
{
    BuildUnit[] units;
    foreach (path; packages)
    {
        const name = path.baseName;
        if (auto hosts = name in hostsOf)
            foreach (host; *hosts)
                units ~= BuildUnit(path, name, host);
        else
            units ~= BuildUnit(path, name, null);
    }
    return units;
}

@("each_commit.unitsOf.aPackageOncePerListedHost")
@safe pure
unittest
{
    const units = unitsOf(["apps/hue", "libs/base/text-wasm"],
        ["text-wasm": ["wasm32-unknown-wasip1", "wasm32-unknown-wasip2"]]);
    assert(units == [BuildUnit("apps/hue", "hue", null),
        BuildUnit("libs/base/text-wasm", "text-wasm", "wasm32-unknown-wasip1"),
        BuildUnit("libs/base/text-wasm", "text-wasm", "wasm32-unknown-wasip2")]);
    assert(units[0].label == "hue" && units[1].label == "text-wasm (wasm32-unknown-wasip1)");
}

/++
Which of `units` the planning error `why` refuses: the one it names, as
`<name>: …` for the build platform or `<name> for <host>: …` for a host, or
`units.length` when it names none of them.
+/
size_t refusedUnit(in BuildUnit[] units, string why) @safe pure
{
    foreach (i, unit; units)
        if (unit.host.length ? why.startsWith(unit.name ~ " for " ~ unit.host ~ ":") : why.startsWith(unit.name ~ ":"))
            return i;
    return units.length;
}

@("each_commit.refusedUnit.byNameAndHost")
@safe pure
unittest
{
    const units = [BuildUnit("apps/hue", "hue", null),
        BuildUnit("libs/base/text-wasm", "text-wasm", "wasm32-unknown-wasip1"),
        BuildUnit("libs/base/text-wasm", "text-wasm", "wasm32-unknown-wasip2")];
    assert(refusedUnit(units, "hue: unknown configuration") == 0);
    assert(refusedUnit(units, "text-wasm for wasm32-unknown-wasip2: no such file") == 2);
    assert(refusedUnit(units, "SPARKLES_DUB_SOURCES is not set") == 3, "no unit's refusal");
}

/++
Whether `name` built for host `config` in a run: it has a compile, archive
or link of its own package for that host (an application's link, a
library's compile or archive), and every one succeeded. `variantConfig`
gives an action's variant's host, and `outcomes` each task's outcome.
+/
bool unitBuilt(const ActionGraph graph, scope string delegate(size_t variant) @safe variantConfig,
    const OutcomeKind[string] outcomes, string name, string config) @safe
{
    import sparkles.build_graph.actions : ActionKind;

    bool built, failed;
    foreach (ref a; graph.actions)
    {
        if (a.kind != ActionKind.compile && a.kind != ActionKind.archive && a.kind != ActionKind.link)
            continue;
        const colon = a.id.text.indexOf(':');
        if (colon < 0 || !a.id.text[colon + 1 .. $].startsWith("sparkles." ~ name ~ ":") || variantConfig(a.variant) != config)
            continue;
        built = true;
        failed |= outcomes.get(a.id.text, OutcomeKind.skipped) != OutcomeKind.succeeded;
    }
    return built && !failed;
}

/// A library has no link: its compile succeeding builds it; an action of
/// another host, or of another package, does not count.
@("each_commit.unitBuilt.librariesAndHosts")
@safe unittest
{
    import sparkles.build_graph.actions : Action, ActionKind;
    import sparkles.build_primitives.task.model : taskId;

    ActionGraph g;
    Action act(ActionKind kind, string id, size_t variant)
    {
        Action a;
        a.kind = kind;
        a.id = TaskId(id);
        a.variant = variant;
        return a;
    }
    g.actions = [act(ActionKind.compile, "compile:sparkles.base:library:ldc:a", 0),
        act(ActionKind.compile, "compile:sparkles.hue:application:ldc:b", 1),
        act(ActionKind.link, "link:sparkles.hue:application:ldc:b", 1),
        act(ActionKind.compile, "compile:sparkles.base-extra:library:ldc:c", 0)];
    const configs = ["x86_64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"];
    string configOf(size_t v) => configs[v];
    auto outcomes = ["compile:sparkles.base:library:ldc:a": OutcomeKind.succeeded,
        "compile:sparkles.hue:application:ldc:b": OutcomeKind.succeeded,
        "link:sparkles.hue:application:ldc:b": OutcomeKind.failed];
    assert(unitBuilt(g, &configOf, outcomes, "base", configs[0]), "a library built by its compile");
    assert(!unitBuilt(g, &configOf, outcomes, "hue", configs[0]), "a failed link");
    assert(!unitBuilt(g, &configOf, outcomes, "base", "wasm32-unknown-wasip1"), "nothing for that host");
    assert(!unitBuilt(g, &configOf, outcomes, "base-extra", configs[0]), "a compile that never ran");
}

/// One commit of the range.
struct RangeCommit
{
    string sha;     /// abbreviated
    string subject; /// the first line of its message
}

/++
The commits `git log --reverse --format='%h %s' <base>..HEAD` printed, oldest
first, the order a bisect-minded reader walks them in.
+/
RangeCommit[] parseCommitRange(scope const(char)[] logOutput) @safe pure
{
    RangeCommit[] commits;
    foreach (line; logOutput.lineSplitter)
    {
        const l = line.strip;
        if (l.length == 0)
            continue;
        const sp = l.indexOf(' ');
        commits ~= sp < 0
            ? RangeCommit(l.idup, "")
            : RangeCommit(l[0 .. sp].idup, l[sp + 1 .. $].idup);
    }
    return commits;
}

@("each_commit.parseCommitRange.oldestFirstWithSubjects")
@safe pure
unittest
{
    const r = parseCommitRange("d0d91e6 fix(ui): cut text (LAY14)\n7bf3f4b feat(ui.dock): toolbars\n\n");
    assert(r.length == 2);
    assert(r[0] == RangeCommit("d0d91e6", "fix(ui): cut text (LAY14)"));
    assert(r[1].sha == "7bf3f4b" && r[1].subject == "feat(ui.dock): toolbars");
    assert(parseCommitRange("").length == 0, "an empty range is no commits");
}

/++
Maps package names to the sub-package paths the root recipe declares
(`apps/hue`, `libs/ui`). A name that matches none is returned in `unknown`,
so a typo fails before any worktree is created rather than after an hour of
builds that never included the package it meant.
+/
string[] selectPackages(in string[] requested, in string[] subPackagePaths,
    out string[] unknown) @safe pure
{
    string[] chosen;
    foreach (name; requested)
    {
        bool found;
        foreach (path; subPackagePaths)
            if (path.baseName == name)
            {
                if (!chosen.canFind(path))
                    chosen ~= path;
                found = true;
                break;
            }
        if (!found)
            unknown ~= name;
    }
    return chosen;
}

@("each_commit.selectPackages.namesResolveToPathsAndTyposAreKept")
@safe pure
unittest
{
    const paths = ["apps/hue", "apps/ui-gallery", "libs/ui", "apps/diagram",
        "libs/base/text-wasm", "libs/core-cli/table-wasm", "libs/wired/wired-wasm",
        "libs/dub-manifest/dub-manifest-nix-wasm"];
    string[] unknown;
    const chosen = selectPackages(["ui", "hue", "hue", "gallery"], paths, unknown);
    assert(chosen == ["libs/ui", "apps/hue"], "in request order, once each");
    assert(unknown == ["gallery"], "a name no package has is reported");

    selectPackages(defaultEachCommitPackages, paths, unknown);
    assert(unknown.length == 0, "the defaults are real packages");
}

/// One package that did not build at one commit.
struct CommitFailure
{
    RangeCommit commit;
    string pkg;
}

/// The closing report, one line per failure, oldest commit first.
string failureReport(in CommitFailure[] failures, size_t commits,
    size_t packages) @safe pure
{
    import std.conv : text;

    if (failures.length == 0)
        return text("every commit builds: ", commits, " commit(s) × ",
            packages, " package(s)");
    string s = text(failures.length, " build(s) failed across ", commits,
        " commit(s):");
    foreach (f; failures)
        s ~= text("\n  ", f.commit.sha, "  :", f.pkg, "  ", f.commit.subject);
    return s;
}

@("each_commit.failureReport.namesTheCommitAndThePackage")
@safe pure
unittest
{
    assert(failureReport(null, 3, 2) == "every commit builds: 3 commit(s) × 2 package(s)");
    const f = [CommitFailure(RangeCommit("7bf3f4b", "feat: x"), "hue")];
    assert(failureReport(f, 3, 2)
        == "1 build(s) failed across 3 commit(s):\n  7bf3f4b  :hue  feat: x");
}

/++
The edges that let an action of `later` reuse the result its namesake in
`earlier` publishes (ci task-DAG CIC21): one from each action of `earlier`
to the action of `later` predicted to share its key, so the later one is
looked up only once the earlier one has published, and hits. Every other
action of `later` waits for nothing of `earlier`'s, as its key will differ.

An action is predicted to share its key when it has the same id, kind,
action and outputs in both plans, no in-tree path its arguments name (a
source, an import root, a working directory) holds a file of `changed` (the
paths `git diff --name-only` lists between the two commits), and each
producer it reads (`$IN(<id>)`) is predicted to share its own. A wrong
prediction costs time, never a result: a key that differs misses after
waiting, and one that matches without an edge executes twice.

`earlierSuffix` and `laterSuffix` are the parts' id suffixes in the run.
+/
TaskEdge[] reuseEdges(ref const ActionGraph earlier, string earlierSuffix, ref const ActionGraph later,
    string laterSuffix, const string[] changed) @safe
{
    import sparkles.build_graph.execute : withSuffix;
    import sparkles.build_primitives.task.model : EdgeCondition, EdgeReason;

    enum Verdict : ubyte { unknown, deciding, same, differs }
    Verdict[string] verdicts;

    bool shared_(TaskId id)
    {
        if (auto v = id.text in verdicts)
            return *v == Verdict.same;
        verdicts[id.text] = Verdict.deciding; // an acyclic plan never meets it again
        const a = later.find(id);
        const b = earlier.find(id);
        bool same = a !is null && b !is null && a.kind == b.kind && a.action == b.action
            && a.outputs == b.outputs;
        if (same)
            foreach (arg; argumentsOf(a.action))
            {
                foreach (producer; producersIn(arg))
                    same = same && shared_(producer);
                foreach (path; inTreePaths(arg))
                    same = same && !changed.any!(f => f == path || f.startsWith(path ~ "/"));
                if (!same)
                    break;
            }
        verdicts[id.text] = same ? Verdict.same : Verdict.differs;
        return same;
    }

    TaskEdge[] edges;
    foreach (ref a; later.actions)
        if (shared_(a.id))
            edges ~= TaskEdge(withSuffix(a.id, earlierSuffix), withSuffix(a.id, laterSuffix),
                EdgeCondition.onCompletion, EdgeReason.reuse);
    return edges;
}

// Every argument of `action` that may name a path: a process's arguments,
// working directory and environment values; an in-process action's arguments.
private string[] argumentsOf(const TaskAction action) @safe
{
    import std.sumtype : match;

    return action.match!(
        (ref const ProcessAction p) => p.argv.dup ~ p.cwd ~ p.envDelta.map!(e => e.value).array,
        (ref const InProcessAction i) => i.arguments.dup,
        (ref const _) => string[].init);
}

// The producers `$IN(<id>)` in `arg` names.
private TaskId[] producersIn(string arg) @safe pure
{
    import std.array : split;
    import sparkles.build_primitives.task.model : taskId;

    TaskId[] ids;
    for (auto at = arg.indexOf("$IN("); at >= 0; at = arg.indexOf("$IN("))
    {
        arg = arg[at + 4 .. $];
        const close = arg.indexOf(')');
        if (close < 0)
            break;
        const id = taskId(arg[0 .. close].split(":"));
        if (id.hasValue)
            ids ~= id.value;
        arg = arg[close + 1 .. $];
    }
    return ids;
}

/++
The in-tree paths `arg` may name, relative to the worktree: each piece of it
between `=`s, an option's `-I`, `-J`, `-L` or `-P-I` prefix taken off, that
is `$ROOT/`-relative or relative. A placeholder, an absolute path, an option
and the root itself (`.`) name none.
+/
string[] inTreePaths(string arg) @safe pure
{
    import std.array : split;

    string[] paths;
    foreach (piece; arg.split("="))
    {
        foreach (prefix; ["-P-I", "-I", "-J", "-L"])
            if (piece.startsWith(prefix))
            {
                piece = piece[prefix.length .. $];
                break;
            }
        if (piece.startsWith("$ROOT/"))
            piece = piece["$ROOT/".length .. $];
        while (piece.endsWith("/"))
            piece = piece[0 .. $ - 1];
        if (piece.length && piece != "." && piece[0] != '$' && piece[0] != '/' && piece[0] != '-')
            paths ~= piece;
    }
    return paths;
}

@("each_commit.inTreePaths.sourcesAndRootsNotOptionsOrPlaceholders")
@safe pure
unittest
{
    assert(inTreePaths("libs/ui/src/sparkles/ui/dock.d") == ["libs/ui/src/sparkles/ui/dock.d"]);
    assert(inTreePaths("-I=libs/base/src/") == ["libs/base/src"]);
    assert(inTreePaths("-Ilibs/base/src") == ["libs/base/src"]);
    assert(inTreePaths("-J=$ROOT/apps/hue/views") == ["apps/hue/views"]);
    assert(inTreePaths("--ffile-prefix-map=$ROOT=.") is null);
    assert(inTreePaths("-of=$OUTREL/hue") is null);
    assert(inTreePaths("$IN(compile:sparkles.ui:library:ldc:abc)/ui.o") is null);
    assert(inTreePaths("/nix/store/x-ldc/bin/ldc2") is null);
}

@("each_commit.reuseEdges.anUnchangedClosureWaitsAndAChangedOneRunsAtOnce")
@safe
unittest
{
    import sparkles.build_graph.actions : Action, ActionKind, DeclaredOutput;
    import sparkles.build_primitives.task.model : EdgeReason, taskId;

    const base = taskId("compile", "sparkles.base", "library", "ldc", "b1").value;
    const ui = taskId("compile", "sparkles.ui", "library", "ldc", "u1").value;
    const link = taskId("link", "sparkles.hue", "application", "ldc", "h1").value;
    Action compile(TaskId id, string[] argv)
        => Action(ActionKind.compile, id, 0, TaskAction(ProcessAction(argv: argv)), [DeclaredOutput("o.o")], 2);
    ActionGraph plan(string uiFlag)
    {
        ActionGraph g;
        g.actions ~= compile(base, ["ldc2", "-I=libs/base/src", "libs/base/src/a.d", "-of=$OUT/o.o"]);
        g.actions ~= compile(ui, ["ldc2", "-I=libs/ui/src", "libs/ui/src/b.d", uiFlag, "-of=$OUT/o.o"]);
        g.actions ~= Action(ActionKind.link, link, 0, TaskAction(ProcessAction(argv: ["ldc2",
            "$IN(" ~ base.text ~ ")/o.o", "$IN(" ~ ui.text ~ ")/o.o", "-of=$OUT/hue"])), [DeclaredOutput("hue")], 2);
        return g;
    }
    const before = plan("-g");

    // A change beneath ui's sources: base waits for its earlier namesake;
    // ui, and the link reading it, start at once.
    const same = plan("-g"), optimized = plan("-O");
    auto edges = reuseEdges(before, "c1", same, "c2", ["libs/ui/src/b.d"]);
    assert(edges.length == 1, text(edges));
    assert(edges[0].prerequisite.text == base.text ~ ":c1" && edges[0].dependent.text == base.text ~ ":c2");
    assert(edges[0].reason == EdgeReason.reuse);

    // Nothing any action reads changed: every action waits.
    assert(reuseEdges(before, "c1", same, "c2", ["docs/x.md"]).length == 3);

    // ui's flags changed: so did its key, and the link's.
    assert(reuseEdges(before, "c1", optimized, "c2", null).length == 1);
}
