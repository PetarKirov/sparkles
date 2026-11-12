/++
Focused package selection ([SPEC TDS4–TDS8](../../../../../../docs/specs/build-primitives/task-dag/SPEC.md)):
`--from` selectors, `--since` change sets judged by the packages' input sets,
dependency and dependent closure, platform eligibility, and the reasons each
package was selected.

A changed path selects by claims, not by directories
([design](../../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
BGW6, BGW12): a package is seeded when a request rooted at it is affected, that
is, when a package and configuration of the request's closure claims the
path, when a workspace input holds it, or, for a request whose reads are not
all stated, on any change. Where the path lies decides only who it is
reported under.

$(LREF selectPackages) is pure: it evaluates the selection algebra over a
$(REF PackageGraph, sparkles,build_primitives,workspace,package_graph) and the
seeds $(LREF seedsByClaims) derived from a change set. $(LREF gitChangesSince)
is the one part that runs git, through `runGit`, so an inherited `GIT_DIR`
cannot redirect it. $(LREF planPackages) puts the two together for a
repository: it reads the workspace, resolves the requests and builds the
input sets.
+/
module sparkles.build_primitives.workspace.select;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.range.primitives : put;

import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.wire_names : AnyFormat, WireCase;
import sparkles.base.text.writers : writeEnumMemberName, writeValue;

import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;
import sparkles.build_primitives.workspace.discovery : Workspace;
import sparkles.build_primitives.workspace.input_sets : ConfiguredPackage, InputSets, Request;
import sparkles.build_primitives.workspace.package_graph : normalizeRepoPath, PackageEdge, PackageGraph, PackageId,
    RecipeRole;

// ─────────────────────────────────────────────────────────────────────────────
// The selection algebra
// ─────────────────────────────────────────────────────────────────────────────

/// What to select. Without `from` and `since`, every package is seeded.
struct SelectionRequest
{
    /// `--from` selectors, each a short name, qualified name, or path, or a
    /// git-style glob over any of those.
    const(string)[] from;
    /// Whether `--since` was given; `changes` then seeds.
    bool since;
    /// With `since`: the seeds the change set gives, by graph index
    /// ($(LREF seedsByClaims)).
    ChangeSeeds changes;
    bool dependencies; /// `--dependencies`
    bool dependents;   /// `--dependents`
}

/// Why a package was selected.
@WireCase(CaseStyle.kebabCase)
enum ReasonKind
{
    all,            /// no selector was given
    from,           /// a `--from` selector matched; `detail` is the selector
    changed,        /// its request claims a changed path; `detail` is the path
    workspaceInput, /// a workspace input changed; `detail` is the path
    /// what its request reads is not all stated, and something changed;
    /// `detail` says what is not stated
    uncertain,
    dependencyOf,   /// a selected package depends on it; `detail` is that package
    dependentOf,    /// it depends on a selected package; `detail` is that package
}

/// One reason.
struct SelectionReason
{
    ReasonKind kind; ///
    string detail;   ///

    int opCmp(const SelectionReason rhs) const @safe pure nothrow @nogc
    {
        if (kind != rhs.kind)
            return kind < rhs.kind ? -1 : 1;
        return detail < rhs.detail ? -1 : detail > rhs.detail;
    }
}

/// A selected package.
struct SelectedPackage
{
    PackageId id;              ///
    uint graphIndex;           /// its index in the package graph
    SelectionReason[] reasons; /// sorted, without duplicates
    /// The host is outside its platforms: it stays visible as a skipped node.
    bool platformSkipped;
}

/// The selected packages, by id, and the dependency edges induced among them.
struct Selection
{
    SelectedPackage[] packages; ///
    /// Indices into `packages`, by dependent then dependency.
    PackageEdge[] edges;
}

/// Why selection failed.
@WireCase(CaseStyle.kebabCase)
enum SelectionErrorKind
{
    unmatchedSelector, /// a `--from` selector matched no package
    emptySelection,    /// nothing was seeded
    baseUnresolved,    /// `--since` found no base revision
    gitFailed,         /// a git query failed
    discoveryFailed,   /// the package graph could not be discovered
}

/// A selection error; `detail` names the selector, revision, or git output.
struct SelectionError
{
    SelectionErrorKind kind; ///
    string detail;           ///

    void toString(Writer)(ref Writer w) const
    {
        writeEnumMemberName!AnyFormat(w, kind);
        if (detail.length)
        {
            put(w, ": ");
            put(w, detail);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seeds from claims
// ─────────────────────────────────────────────────────────────────────────────

/// What a change set seeds.
struct ChangeSeeds
{
    /// By graph index: the reasons the package is seeded; empty when it is
    /// not.
    SelectionReason[][] byPackage;
    /// The changed paths no set and no workspace input holds, in the order
    /// given: they affect no request (BGW12).
    string[] unclaimed;
}

/**
The seeds a change to the repository-relative `changed` paths gives
(BGW12): the root of each request whose closure holds a pair claiming one
(`changed`), of every request when a workspace input holds one
(`workspaceInput`), and of each request whose reads are not all stated when
anything changed (`uncertain`, BGW4), over the `graph` the sets were built
from.

A path need not exist: membership is decided without the file, so a removed
path is judged like any other (BGW13). Nor are the base revision's sets
needed. A set that held a removed path at the base revision and does not now
was changed by its recipe or by the root recipe, and that recipe is itself a
changed path, claimed by its package or a workspace input. Reads no file.
*/
ChangeSeeds seedsByClaims(ref InputSets inputs, const ref PackageGraph graph, scope const(Request)[] requests,
    scope const(string)[] changed) @safe nothrow
{
    ChangeSeeds seeds;
    seeds.byPackage = new SelectionReason[][graph.packages.length];
    auto claimedBy = new string[][inputs.length];
    string[] everywhere;
    foreach (path; changed)
    {
        bool any;
        inputs.eachClaimant(path, (size_t i) {
            claimedBy[i] ~= path;
            any = true;
        });
        if (inputs.inWorkspace(path))
        {
            everywhere ~= path;
            any = true;
        }
        if (!any)
            seeds.unclaimed ~= path;
    }

    foreach (ref request; requests)
    {
        if (request.root < 0)
            continue;
        auto reasons = &seeds.byPackage[request.root];
        foreach (path; everywhere)
            *reasons ~= SelectionReason(ReasonKind.workspaceInput, path);
        string unstated = request.unresolved;
        foreach (pair; request.closure)
        {
            const k = inputs.indexOf(pair);
            if (k < 0 || inputs.isOpaque(k))
                if (unstated is null)
                    unstated = describe(graph, pair, k < 0 ? "has no input set" : "has an opaque entry");
            if (k >= 0)
                foreach (path; claimedBy[k])
                    *reasons ~= SelectionReason(ReasonKind.changed, path);
        }
        if (unstated !is null && changed.length)
            *reasons ~= SelectionReason(ReasonKind.uncertain, unstated);
    }
    return seeds;
}

// `sparkles:ui (gpu-effects) has an opaque entry`.
private string describe(const ref PackageGraph graph, ConfiguredPackage pair, string what) @safe pure nothrow
    => graph.packages[pair.package_].id.name ~ (pair.configuration.length ? " (" ~ pair.configuration ~ ")" : "")
        ~ " " ~ what;

/**
Whether `text` matches the git-style glob `pattern` as a whole: `*` and `?`
stop at `/`, `**` crosses it, and `\` escapes the next character. A selector
names a package, not a file, so this is not a fileset pattern.
*/
bool gitGlobMatch(in string pattern, in const(char)[] text) @safe pure nothrow
    => globMatchAt(pattern, 0, text, 0);

///
@("build_primitives.workspace.select.gitGlobMatch")
@safe pure nothrow unittest
{
    assert(gitGlobMatch("sparkles:ui-*", "sparkles:ui-tui"));
    assert(gitGlobMatch("libs/ui*", "libs/ui-sdl3"));
    assert(!gitGlobMatch("libs/*", "libs/ui/nested"), "`*` stops at `/`");
    assert(gitGlobMatch("libs/**", "libs/ui/nested"));
    assert(gitGlobMatch("ba?e", "base"));
    assert(!gitGlobMatch(`b\*`, "bx"));
}

private bool globMatchAt(in string pattern, size_t patternIndex, in const(char)[] text,
    size_t textIndex) @safe pure nothrow
{
    while (patternIndex < pattern.length)
    {
        const ch = pattern[patternIndex];
        if (ch == '*')
        {
            if (patternIndex + 1 < pattern.length && pattern[patternIndex + 1] == '*')
            {
                size_t next = patternIndex + 2;
                while (next < pattern.length && pattern[next] == '*')
                    next++;

                if (next < pattern.length && pattern[next] == '/')
                {
                    if (globMatchAt(pattern, next + 1, text, textIndex))
                        return true;
                }

                foreach (i; textIndex .. text.length + 1)
                    if (globMatchAt(pattern, next, text, i))
                        return true;

                return false;
            }

            const next = patternIndex + 1;
            if (globMatchAt(pattern, next, text, textIndex))
                return true;

            size_t i = textIndex;
            while (i < text.length && text[i] != '/')
            {
                i++;
                if (globMatchAt(pattern, next, text, i))
                    return true;
            }
            return false;
        }

        if (ch == '?')
        {
            if (textIndex >= text.length || text[textIndex] == '/')
                return false;

            patternIndex++;
            textIndex++;
            continue;
        }

        if (ch == '\\' && patternIndex + 1 < pattern.length)
            patternIndex++;

        if (textIndex >= text.length || pattern[patternIndex] != text[textIndex])
            return false;

        patternIndex++;
        textIndex++;
    }

    return textIndex == text.length;
}

/// Whether `selector` is a glob rather than a literal.
bool isGlob(scope const(char)[] selector) @safe pure nothrow @nogc
{
    foreach (c; selector)
        if (c == '*' || c == '?' || c == '\\')
            return true;
    return false;
}


/**
Evaluates [SPEC TDS7]'s algebra: seed from `--from` and/or `--since` (their
union), or every package; add the transitive dependency and/or dependent
closure of the $(I seed) — both closures computed from the original seed and
unioned, so neither expands the other's result; mark platform-ineligible
packages skipped; sort by id and induce the edges among the selected.

Errors: a selector (literal or glob) that matches nothing, and a seed that is
empty — a misspelled selector or a change set no request claims never
becomes a green no-op. The empty seed's error names the changed paths nothing
claims. Selected packages that are all platform-skipped are not an error.
*/
PlanExpected!(Selection, SelectionError) selectPackages(const ref PackageGraph graph,
    const ref SelectionRequest request, scope const(string)[] hostTokens) @safe pure nothrow
{
    const count = graph.packages.length;
    auto reasons = new SelectionReason[][count];
    auto seeded = new bool[count];
    void seed(size_t i, ReasonKind kind, string detail)
    {
        seeded[i] = true;
        reasons[i] ~= SelectionReason(kind, detail);
    }

    if (!request.from.length && !request.since)
        foreach (i; 0 .. count)
            seed(i, ReasonKind.all, null);

    foreach (selector; request.from)
    {
        const glob = isGlob(selector);
        const normalized = normalizeRepoPath(selector);
        bool matched;
        foreach (i, ref p; graph.packages)
        {
            const hit = glob
                ? gitGlobMatch(selector, p.shortName) || gitGlobMatch(selector, p.id.name)
                    || gitGlobMatch(normalized, p.path)
                : selector == p.shortName || selector == p.id.name || normalized == p.path;
            if (hit)
            {
                matched = true;
                seed(i, ReasonKind.from, selector);
            }
        }
        if (!matched)
            return planErr!Selection(SelectionError(SelectionErrorKind.unmatchedSelector, selector));
    }

    if (request.since)
        foreach (i, rs; request.changes.byPackage)
            foreach (r; rs)
                seed(i, r.kind, r.detail);

    bool any;
    foreach (s; seeded)
        any |= s;
    if (!any)
        return planErr!Selection(SelectionError(SelectionErrorKind.emptySelection,
            request.since ? noRequestClaims(request.changes.unclaimed) : "no package was seeded"));

    // Both closures start from the seed alone, so the union is the same
    // whichever is computed first.
    auto selected = seeded.dup;
    if (request.dependencies)
        closeOver(graph, seeded, selected, reasons, towardDependencies: true);
    if (request.dependents)
        closeOver(graph, seeded, selected, reasons, towardDependencies: false);

    Selection selection;
    auto position = new uint[count];
    foreach (i, ref p; graph.packages) // already sorted by id
    {
        if (!selected[i])
            continue;
        position[i] = cast(uint) selection.packages.length;
        auto rs = reasons[i];
        rs.sort();
        size_t kept;
        foreach (j, r; rs)
            if (j == 0 || r != rs[kept - 1])
                rs[kept++] = r;
        selection.packages ~= SelectedPackage(p.id, cast(uint) i, rs[0 .. kept],
            !p.platforms.allows(hostTokens));
    }
    foreach (e; graph.edges) // by dependent, then dependency: order is kept
        if (selected[e.dependency] && selected[e.dependent])
            selection.edges ~= PackageEdge(position[e.dependency], position[e.dependent]);

    import core.lifetime : move;

    return planOk!SelectionError(move(selection));
}

// The empty-selection detail of `--since`: what changed that nothing claims.
private string noRequestClaims(scope const(string)[] unclaimed) @safe pure nothrow
{
    enum shown = 5;
    string detail = "no request claims a path changed since the base revision";
    foreach (i, path; unclaimed)
    {
        if (i == shown)
        {
            detail ~= ", …";
            break;
        }
        detail ~= (i ? ", " : ": ") ~ path;
    }
    return detail;
}

// Adds the transitive closure of `seed` in one direction to `selected`,
// recording for each added package every in-closure neighbour that pulled it.
private void closeOver(const ref PackageGraph graph, scope const(bool)[] seed, bool[] selected,
    SelectionReason[][] reasons, bool towardDependencies) @safe pure nothrow
{
    auto inClosure = seed.dup;
    uint[] queue;
    foreach (i, s; seed)
        if (s)
            queue ~= cast(uint) i;
    while (queue.length)
    {
        const at = queue[0];
        queue = queue[1 .. $];
        foreach (e; graph.edges)
        {
            const from = towardDependencies ? e.dependent : e.dependency;
            const to = towardDependencies ? e.dependency : e.dependent;
            if (from != at)
                continue;
            if (!seed[to])
                reasons[to] ~= SelectionReason(
                    towardDependencies ? ReasonKind.dependencyOf : ReasonKind.dependentOf,
                    graph.packages[at].id.name);
            if (!inClosure[to])
            {
                inClosure[to] = true;
                selected[to] = true;
                queue ~= to;
            }
        }
    }
}

/**
Writes `selection` as the test-only planner shows it: each package with its
reasons (and a platform skip), then the induced edges.

---
packages (2):
    sparkles:base: from=base
    sparkles:ui [platform-skipped]: dependent-of=sparkles:base
edges (1):
    sparkles:base -> sparkles:ui
---
*/
void writeSelectionPlan(Writer)(ref Writer w, const ref Selection selection)
{
    put(w, "packages (");
    writeValue(w, selection.packages.length);
    put(w, "):\n");
    foreach (ref p; selection.packages)
    {
        put(w, "  ");
        put(w, p.id.name);
        if (p.platformSkipped)
            put(w, " [platform-skipped]");
        put(w, ':');
        foreach (i, r; p.reasons)
        {
            put(w, i ? ", " : " ");
            writeEnumMemberName!AnyFormat(w, r.kind);
            if (r.detail.length)
            {
                put(w, '=');
                put(w, r.detail);
            }
        }
        put(w, '\n');
    }
    put(w, "edges (");
    writeValue(w, selection.edges.length);
    put(w, "):\n");
    foreach (e; selection.edges)
    {
        put(w, "  ");
        put(w, selection.packages[e.dependency].id.name);
        put(w, " -> ");
        put(w, selection.packages[e.dependent].id.name);
        put(w, '\n');
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// `--since`: the git half
// ─────────────────────────────────────────────────────────────────────────────

/// What `--since` found.
struct SinceChanges
{
    string baseRef;   /// the revision named or resolved
    string mergeBase; /// `merge-base(baseRef, HEAD)`
    string[] changes; /// repository-relative, sorted, each once
}

/**
The paths changed from `merge-base(sinceRef, HEAD)` through the working tree
— committed, staged, unstaged, and untracked-but-not-ignored.

A null `sinceRef` resolves the current branch's upstream, else `origin/main`;
neither existing is `SelectionErrorKind.baseUnresolved`. Each path appears
once, whether it was created, modified or removed: input sets judge a path
without the file, so whether it exists does not matter ($(LREF seedsByClaims)).
Renames count as a removal plus a creation. Every git call goes through
`runGit`.
*/
PlanExpected!(SinceChanges, SelectionError) gitChangesSince(string repoRoot, string sinceRef) @safe
{
    import std.string : strip;
    import sparkles.build_primitives.git_env : runGit;

    alias fail = (kind, detail) => planErr!SinceChanges(SelectionError(kind, detail));

    static string[] fields(string output) @safe pure nothrow
    {
        string[] result;
        size_t start;
        foreach (i, c; output)
            if (c == '\0')
            {
                result ~= output[start .. i];
                start = i + 1;
            }
        if (start < output.length)
            result ~= output[start .. $];
        return result;
    }

    SinceChanges since;
    try
    {
        auto git(scope const(string)[] args) => runGit(args, repoRoot);

        if (sinceRef.length == 0)
        {
            const upstream = git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]);
            if (upstream.status == 0)
                sinceRef = upstream.output.strip;
            else if (git(["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]).status == 0)
                sinceRef = "origin/main";
            else
                return fail(SelectionErrorKind.baseUnresolved,
                    "the branch has no upstream and origin/main does not exist; pass --since REF");
        }
        since.baseRef = sinceRef;

        const mergeBase = git(["merge-base", sinceRef, "HEAD"]);
        if (mergeBase.status != 0)
            return fail(SelectionErrorKind.baseUnresolved,
                "no merge base of " ~ sinceRef ~ " and HEAD: " ~ mergeBase.output.strip);
        since.mergeBase = mergeBase.output.strip;

        // Three views of "changed": the worktree against the base, the index
        // against the base (a path staged and then removed from the worktree
        // is in neither the base nor the worktree), and untracked files. A
        // path may appear in several; it is reported once.
        bool[string] changed; // membership only; the result is sorted below
        const worktree = git(["diff", "--name-only", "-z", "--no-renames", since.mergeBase, "--"]);
        if (worktree.status != 0)
            return fail(SelectionErrorKind.gitFailed, "git diff: " ~ worktree.output.strip);
        foreach (path; fields(worktree.output))
            changed[path] = true;

        const index = git(["diff", "--cached", "--name-only", "-z", "--no-renames", since.mergeBase, "--"]);
        if (index.status != 0)
            return fail(SelectionErrorKind.gitFailed, "git diff --cached: " ~ index.output.strip);
        foreach (path; fields(index.output))
            changed[path] = true;

        const untracked = git(["ls-files", "--others", "--exclude-standard", "-z"]);
        if (untracked.status != 0)
            return fail(SelectionErrorKind.gitFailed, "git ls-files: " ~ untracked.output.strip);
        foreach (path; fields(untracked.output))
            changed[path] = true;

        foreach (path, _; changed)
            since.changes ~= path;
    }
    catch (Exception e)
        return fail(SelectionErrorKind.gitFailed, e.msg);

    since.changes.sort();

    import core.lifetime : move;

    return planOk!SelectionError(move(since));
}

// ─────────────────────────────────────────────────────────────────────────────
// The focused-selection planner
// ─────────────────────────────────────────────────────────────────────────────

/// `ci test`'s focused-selection options ([SPEC TDS4, TDS5]).
struct FocusOptions
{
    import sparkles.build_primitives.resolve.platform : BuildPlatform;
    import sparkles.build_primitives.resolve.project : RegistrySources;

    const(string)[] from; /// `--from`
    bool since;           /// `--since` given
    string sinceRef;      /// its value; null resolves the upstream, else `origin/main`
    bool dependencies;    /// `--dependencies`
    bool dependents;      /// `--dependents`

    /**
    What the consumer states of the workspace inputs (BGW12): the toolchain's
    definition as `patterns`, the importable modules' first components as
    `moduleRoots`, and, in `read`, the files besides the recipes that
    planning read, such as the lockfiles the registry came from. The
    recipes and the planner's inputs are added.
    */
    WorkspaceInputs workspace;
    /// The package of the command that plans: its own sets are workspace
    /// inputs (D54). `sparkles:ci`.
    string plannerPackage;
    /// The libraries it plans and runs the work with: their closures are
    /// workspace inputs (D54). `sparkles:build-primitives`.
    const(string)[] plannerLibraries;

    /// The platform requests are resolved for.
    BuildPlatform platform;
    /// The source directory of each registry package.
    RegistrySources registry;
}

import sparkles.build_primitives.workspace.input_sets : WorkspaceInputs;

/// A discovered graph and the selection made from it.
struct PackagePlan
{
    PackageGraph graph;  ///
    Selection selection; ///
    /// What `--since` found; `baseRef` is empty without `--since`.
    SinceChanges since;
    /// The requests a `--since` selection judged, one per package, by graph
    /// index; empty without `--since`.
    Request[] requests;
}

/**
Reads the workspace under `repoRoot`, builds its package graph for `role`,
and selects ([SPEC TDS7] steps 1–10). With `--since`, it also queries git,
resolves one request per package (its test root for `RecipeRole.test`, its
default configuration for `RecipeRole.build`), builds the input sets, and
seeds by claims. Side-effect free apart from reading recipes and the trees
resolution lists, and running read-only git queries, so a dry run may call
it.

A package the host's platforms exclude is not resolved: its request is its
own sets, and it is reported skipped. A request that fails to resolve is its
root's own sets and uncertain, so any change selects it.
*/
PlanExpected!(PackagePlan, SelectionError) planPackages(string repoRoot, RecipeRole role,
    const FocusOptions options, scope const(string)[] hostTokens) @safe
{
    import std.conv : text;
    import core.lifetime : move;
    import sparkles.build_primitives.workspace.discovery : readWorkspaceAt;
    import sparkles.build_primitives.workspace.package_graph : buildPackageGraph;

    alias fail = (kind, detail) => planErr!PackagePlan(SelectionError(kind, detail));

    PackagePlan plan;
    auto workspace = readWorkspaceAt(repoRoot);
    if (workspace.hasError)
        return fail(SelectionErrorKind.discoveryFailed, text(workspace.error));
    auto graph = buildPackageGraph(workspace.value.rootName, workspace.value.recipes, role, hostTokens);
    if (graph.hasError)
        return fail(SelectionErrorKind.discoveryFailed, text(graph.error));
    plan.graph = move(graph.value);

    SelectionRequest request = SelectionRequest(options.from, options.since,
        dependencies: options.dependencies, dependents: options.dependents);
    if (options.since)
    {
        auto since = gitChangesSince(repoRoot, options.sinceRef);
        if (since.hasError)
            return planErr!PackagePlan(since.error);
        plan.since = move(since.value);

        auto inputs = workspaceInputSets(repoRoot, plan.graph, workspace.value, options, hostTokens);
        plan.requests = packageRequests(repoRoot, plan.graph, inputs, role, options, hostTokens);
        request.changes = seedsByClaims(inputs, plan.graph, plan.requests, plan.since.changes);
    }

    auto selection = selectPackages(plan.graph, request, hostTokens);
    if (selection.hasError)
        return planErr!PackagePlan(selection.error);
    plan.selection = move(selection.value);
    return planOk!SelectionError(move(plan));
}

/// The input sets of `graph`'s packages, read from `workspace`, with the
/// workspace inputs: what `options` states, the recipes read, and the planner's
/// inputs (D54), the planner's libraries resolved for `options.platform`.
InputSets workspaceInputSets(string repoRoot, const ref PackageGraph graph,
    const ref Workspace workspace, const ref FocusOptions options, scope const(string)[] hostTokens) @safe
{
    import sparkles.build_primitives.workspace.input_sets : inputSets;

    WorkspaceInputs stated;
    stated.read = workspace.reads.paths ~ options.workspace.read.dup;
    stated.patterns = options.workspace.patterns.dup;
    stated.moduleRoots = options.workspace.moduleRoots.dup;

    foreach (library; options.plannerLibraries)
    {
        const at = graph.indexOf(PackageId(library));
        if (at < 0)
            continue;
        auto r = resolveRequest(repoRoot, graph, cast(uint) at, testRoot: false, options);
        stated.planner ~= r.closure;
        if (r.unresolved.length)
            stated.planner ~= ConfiguredPackage(cast(uint) at, "");
    }
    const planner = graph.indexOf(PackageId(options.plannerPackage));
    if (planner >= 0)
    {
        auto r = resolveRequest(repoRoot, graph, cast(uint) planner, testRoot: false, options);
        foreach (pair; r.closure)
            if (pair.package_ == planner)
                stated.planner ~= pair;
    }
    return inputSets(graph, workspace.recipes, hostTokens, stated);
}

// One request per package, by graph index (BGW12, D47).
private Request[] packageRequests(string repoRoot, const ref PackageGraph graph, ref InputSets inputs,
    RecipeRole role, const ref FocusOptions options, scope const(string)[] hostTokens) @safe
{
    Request[] requests;
    foreach (i, ref p; graph.packages)
    {
        Request r;
        if (p.platforms.allows(hostTokens))
            r = resolveRequest(repoRoot, graph, cast(uint) i, testRoot: role == RecipeRole.test, options);
        else
        {
            r.name = p.id.name;
            r.root = i;
        }
        if (r.closure.length == 0)
            foreach (k; 0 .. inputs.length)
                if (inputs.key(k).package_ == i)
                    r.closure ~= inputs.key(k);
        requests ~= r;
    }
    return requests;
}

// The request for package `index` of `graph`; unresolved, with an empty
// closure, when resolution fails.
private Request resolveRequest(string repoRoot, const ref PackageGraph graph, uint index, bool testRoot,
    const ref FocusOptions options) @safe
{
    import sparkles.build_primitives.resolve.configure : resolve, ResolveRequest;
    import sparkles.build_primitives.resolve.driver : SystemDriver;
    import sparkles.build_primitives.resolve.platform : BuildPlatform;
    import sparkles.build_primitives.workspace.input_sets : requestOf;

    const p = &graph.packages[index];
    const o = &options.platform;
    auto platform = BuildPlatform(o.platform.dup, o.architecture.dup, o.compiler, o.compilerBinary,
        o.frontendVersion, o.compilerVersion);
    auto request = ResolveRequest(directory: repoRoot, subPackage: p.shortName, platform: platform,
        testRoot: testRoot);
    foreach (name, source; options.registry)
        request.registry[name] = source;
    const resolved = resolve(request, new SystemDriver);
    if (resolved.hasError)
    {
        Request r;
        r.name = p.id.name;
        r.root = index;
        r.unresolved = resolved.error.message;
        return r;
    }
    return requestOf(p.id.name, resolved.value, graph);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.build_primitives.workspace.package_graph : buildPackageGraph, recipe, SubPackageRecipe;

    private enum string[] linux = ["linux", "posix"];

    // base <- wsi (osx-only) <- ui <- ui-tui <- hue; base <- fuzzy; and
    // text-wasm, nested in base's directory, depends on it.
    private PackageGraph fixtureGraph() @safe pure
    {
        return buildPackageGraph("sparkles", [
            recipe("libs/base", `name "base"`),
            recipe("libs/base/text-wasm", `name "text-wasm"
dependency "sparkles:base" path="../../.."`),
            recipe("libs/fuzzy", `name "fuzzy"
dependency "sparkles:base" path="../.."`),
            recipe("libs/wsi", `name "wsi"
platforms "osx"
dependency "sparkles:base" path="../.."`),
            recipe("libs/ui", `name "ui"
dependency "sparkles:wsi" path="../.."`),
            recipe("libs/ui-tui", `name "ui-tui"
dependency "sparkles:ui" path="../.."`),
            recipe("apps/hue", `name "hue"
dependency "sparkles:ui-tui" path="../.."`),
        ], RecipeRole.test, linux).value;
    }

    private string plan(const ref PackageGraph graph, const SelectionRequest request) @safe
    {
        import std.array : appender;
        import std.conv : text;

        auto selected = selectPackages(graph, request, linux);
        if (selected.hasError)
            return text(selected.error);
        auto w = appender!string;
        writeSelectionPlan(w, selected.value);
        return w[];
    }

    // This repository's three reaches, as recipes: the counters' tests
    // compile the harness, the font oracle's tests read font's test data,
    // and ui's tests compile dql. `viewer` builds ui with a generator
    // command, so what it reads is not all stated.
    private SubPackageRecipe[] reachRecipes() @safe pure
        => [
            recipe("libs/base", `name "base"`),
            recipe("libs/test-harness", `name "test-harness"
dependency "sparkles:base" path="../.."`),
            recipe("libs/profiling-counters", `name "profiling-counters"
dependency "sparkles:base" path="../.."
configuration "library" {
}
configuration "unittest" {
    sourcePaths "src" "../test-harness/src"
    importPaths "src" "../test-harness/src"
}`),
            recipe("libs/font", `name "font"
dependency "sparkles:base" path="../.."
configuration "library" {
}
configuration "unittest" {
    importPaths "src" "test"
}`),
            recipe("libs/font-oracle", `name "font-oracle"
dependency "sparkles:font" path="../.."
configuration "library" {
}
configuration "unittest" {
    importPaths "src" "test" "../font/test"
    sourceFiles "../font/test/sparkles/font/fixtures.d"
}`),
            recipe("libs/dql", `name "dql"
dependency "sparkles:base" path="../.."`),
            recipe("libs/ui", `name "ui"
dependency "sparkles:base" path="../.."
configuration "library" {
}
configuration "unittest" {
    sourcePaths "src" "../dql/src"
    importPaths "src" "../dql/src"
}
configuration "gpu-effects" {
    preGenerateCommands "shader-compile --out generated"
}`),
            recipe("apps/hue", `name "hue"
dependency "sparkles:ui" path="../.."`),
            recipe("apps/viewer", `name "viewer"
dependency "sparkles:ui" path="../.."
subConfiguration "sparkles:ui" "gpu-effects"`),
        ];

    // The reaches' graph, input sets and requests: each package's test
    // root, made by hand as a resolution would make it.
    private struct Reaches
    {
        PackageGraph graph;
        InputSets inputs;
        Request[] requests;

        ConfiguredPackage pair(string name, string configuration = "") const @safe
            => ConfiguredPackage(cast(uint) graph.indexOf(PackageId("sparkles:" ~ name)), configuration);

        void add(string name, ConfiguredPackage[] closure) @safe
        {
            closure.sort();
            requests ~= Request(name, closure, root: graph.indexOf(PackageId("sparkles:" ~ name)));
        }

        // The plan `--since` makes of `changed`.
        string since(scope const(string)[] changed...) @safe
        {
            auto seeds = seedsByClaims(inputs, graph, requests, changed);
            return plan(graph, SelectionRequest(since: true, changes: seeds));
        }
    }

    private Reaches reaches(WorkspaceInputs workspace = WorkspaceInputs.init) @safe
    {
        import sparkles.build_primitives.workspace.input_sets : inputSets;

        const recipes = reachRecipes();
        Reaches r;
        r.graph = buildPackageGraph("sparkles", recipes, RecipeRole.test, linux).value;
        r.inputs = inputSets(r.graph, recipes, linux, workspace);
        ConfiguredPackage p(string name, string configuration = "") => r.pair(name, configuration);
        r.add("base", [p("base")]);
        r.add("test-harness", [p("base"), p("test-harness")]);
        r.add("profiling-counters", [p("base"), p("profiling-counters", "unittest")]);
        r.add("font", [p("base"), p("font", "unittest")]);
        r.add("font-oracle", [p("base"), p("font", "library"), p("font-oracle", "unittest")]);
        r.add("dql", [p("base"), p("dql")]);
        r.add("ui", [p("base"), p("ui", "unittest")]);
        r.add("hue", [p("base"), p("ui", "library"), p("hue")]);
        r.add("viewer", [p("base"), p("ui", "gpu-effects"), p("viewer")]);
        return r;
    }
}

@("build_primitives.workspace.select.selectPackages.allWithoutSelectors")
@safe
unittest
{
    const graph = fixtureGraph();
    assert(plan(graph, SelectionRequest()) ==
        "packages (7):\n"
        ~ "  sparkles:base: all\n"
        ~ "  sparkles:fuzzy: all\n"
        ~ "  sparkles:hue: all\n"
        ~ "  sparkles:text-wasm: all\n"
        ~ "  sparkles:ui: all\n"
        ~ "  sparkles:ui-tui: all\n"
        ~ "  sparkles:wsi [platform-skipped]: all\n"
        ~ "edges (6):\n"
        ~ "  sparkles:base -> sparkles:fuzzy\n"
        ~ "  sparkles:ui-tui -> sparkles:hue\n"
        ~ "  sparkles:base -> sparkles:text-wasm\n"
        ~ "  sparkles:wsi -> sparkles:ui\n"
        ~ "  sparkles:ui -> sparkles:ui-tui\n"
        ~ "  sparkles:base -> sparkles:wsi\n");
}

@("build_primitives.workspace.select.selectPackages.fromExactAndGlob")
@safe
unittest
{
    const graph = fixtureGraph();
    // Short name, qualified name, and path (with a trailing slash) all match.
    assert(plan(graph, SelectionRequest(from: ["base", "sparkles:fuzzy", "apps/hue/"])) ==
        "packages (3):\n"
        ~ "  sparkles:base: from=base\n"
        ~ "  sparkles:fuzzy: from=sparkles:fuzzy\n"
        ~ "  sparkles:hue: from=apps/hue/\n"
        ~ "edges (1):\n"
        ~ "  sparkles:base -> sparkles:fuzzy\n");

    // Globs over each form; overlapping matches union into one entry.
    assert(plan(graph, SelectionRequest(from: ["sparkles:ui*", "libs/ui-*", "?ue"])) ==
        "packages (3):\n"
        ~ "  sparkles:hue: from=?ue\n"
        ~ "  sparkles:ui: from=sparkles:ui*\n"
        ~ "  sparkles:ui-tui: from=libs/ui-*, from=sparkles:ui*\n"
        ~ "edges (2):\n"
        ~ "  sparkles:ui-tui -> sparkles:hue\n"
        ~ "  sparkles:ui -> sparkles:ui-tui\n");

    // `*` stops at `/`: `libs/*` is not `libs/base/text-wasm`.
    assert(plan(graph, SelectionRequest(from: ["libs/*"])).canFind("sparkles:ui:"));
    assert(!plan(graph, SelectionRequest(from: ["libs/*"])).canFind("text-wasm"));
}


@("build_primitives.workspace.select.selectPackages.emptyMatchesAreErrors")
@safe
unittest
{
    const graph = fixtureGraph();
    assert(plan(graph, SelectionRequest(from: ["bsae"])) == "unmatched-selector: bsae");
    assert(plan(graph, SelectionRequest(from: ["base", "sparkles:nope-*"]))
        == "unmatched-selector: sparkles:nope-*");
    // A `--since` whose changes no request claims seeds nothing, and says
    // what changed.
    auto unclaimed = ChangeSeeds(new SelectionReason[][graph.packages.length],
        ["README.md", "a", "b", "c", "d", "e"]);
    assert(plan(graph, SelectionRequest(since: true, changes: unclaimed))
        == "empty-selection: no request claims a path changed since the base revision: README.md, a, b, c, d, …");
    assert(plan(graph, SelectionRequest(since: true))
        == "empty-selection: no request claims a path changed since the base revision");
}

/// A changed path seeds the requests whose closures claim it, wherever it
/// lies: a reach selects the reaching package's test root and nothing that
/// builds it as a dependency.
@("build_primitives.workspace.select.seedsByClaims.reaches")
@safe
unittest
{
    auto r = reaches();
    r.requests = r.requests[0 .. $ - 1]; // without viewer, which is uncertain
    // dql's sources: dql, and ui's tests, which compile them. hue builds ui
    // as a library, whose set does not hold them.
    assert(r.since("libs/dql/src/sparkles/dql/query.d") ==
        "packages (2):\n"
        ~ "  sparkles:dql: changed=libs/dql/src/sparkles/dql/query.d\n"
        ~ "  sparkles:ui: changed=libs/dql/src/sparkles/dql/query.d\n"
        ~ "edges (0):\n", r.since("libs/dql/src/sparkles/dql/query.d"));
    // The harness's sources: the harness and the counters' tests.
    assert(r.since("libs/test-harness/src/sparkles/test_harness/run.d") ==
        "packages (2):\n"
        ~ "  sparkles:profiling-counters: changed=libs/test-harness/src/sparkles/test_harness/run.d\n"
        ~ "  sparkles:test-harness: changed=libs/test-harness/src/sparkles/test_harness/run.d\n"
        ~ "edges (0):\n");
    // font's test data: font's tests and the oracle's, not what builds the
    // font library.
    assert(r.since("libs/font/test/sparkles/font/fixtures.d") ==
        "packages (2):\n"
        ~ "  sparkles:font: changed=libs/font/test/sparkles/font/fixtures.d\n"
        ~ "  sparkles:font-oracle: changed=libs/font/test/sparkles/font/fixtures.d\n"
        ~ "edges (1):\n"
        ~ "  sparkles:font -> sparkles:font-oracle\n");
    // A package's own recipe is its input, not every package's.
    assert(r.since("libs/dql/dub.sdl") ==
        "packages (1):\n  sparkles:dql: changed=libs/dql/dub.sdl\nedges (0):\n");
}

/// A path is judged without the file, so a removed one needs neither a probe
/// nor the base revision's packages; a workspace input seeds every request;
/// documentation seeds none.
@("build_primitives.workspace.select.seedsByClaims.removedWorkspaceAndUnclaimed")
@safe
unittest
{
    auto r = reaches(WorkspaceInputs(read: ["dub.sdl", "libs/ui/dub.sdl"], patterns: ["flake.lock"]));
    r.requests = r.requests[0 .. $ - 1]; // without viewer, which is uncertain

    // Nothing here exists: the sets were built from recipe text.
    const removed = r.since("libs/base/src/sparkles/base/gone.d");
    assert(removed.startsWith("packages (8):\n  sparkles:base: changed=libs/base/src/sparkles/base/gone.d\n"),
        removed);

    const root = r.since("dub.sdl");
    assert(root.startsWith("packages (8):\n  sparkles:base: workspace-input=dub.sdl\n"), root);
    assert(r.since("flake.lock").canFind("  sparkles:hue: workspace-input=flake.lock\n"));
    // A sub-package's recipe that planning read is its package's input.
    assert(r.since("libs/ui/dub.sdl") ==
        "packages (2):\n"
        ~ "  sparkles:hue: changed=libs/ui/dub.sdl\n"
        ~ "  sparkles:ui: changed=libs/ui/dub.sdl\n"
        ~ "edges (1):\n"
        ~ "  sparkles:ui -> sparkles:hue\n");

    assert(r.since("README.md", "libs/ui/README.md") == "empty-selection: no request claims a path changed "
        ~ "since the base revision: README.md, libs/ui/README.md");
    // Claimed and unclaimed together: the claimed ones seed.
    assert(r.since("README.md", "libs/dql/src/q.d").startsWith("packages (2):\n"));
}

/// A request whose reads are not all stated is seeded by any change (BGW4):
/// one that reaches a generator's configuration, and one that failed to
/// resolve.
@("build_primitives.workspace.select.seedsByClaims.uncertain")
@safe
unittest
{
    auto r = reaches();
    assert(r.since("README.md") ==
        "packages (1):\n"
        ~ "  sparkles:viewer: uncertain=sparkles:ui (gpu-effects) has an opaque entry\n"
        ~ "edges (0):\n");
    // It is still seeded by what it claims, for a reader of the plan.
    assert(r.since("libs/ui/src/a.d").canFind("  sparkles:viewer: changed=libs/ui/src/a.d, "
        ~ "uncertain=sparkles:ui (gpu-effects) has an opaque entry\n"));
    // Nothing changed: nothing is seeded, uncertain or not.
    assert(r.since().startsWith("empty-selection"));

    r.requests[2].unresolved = "no DUB recipe in libs/profiling-counters";
    assert(r.since("README.md").canFind(
        "  sparkles:profiling-counters: uncertain=no DUB recipe in libs/profiling-counters\n"));
}

@("build_primitives.workspace.select.selectPackages.closuresAreAFixedPointUnion")
@safe
unittest
{
    const graph = fixtureGraph();
    // From `ui`: dependencies wsi, base; dependents ui-tui, hue. The union
    // does not take the dependents of `base` (fuzzy, text-wasm): both
    // closures start from the seed.
    const both = SelectionRequest(from: ["ui"], dependencies: true, dependents: true);
    assert(plan(graph, both) ==
        "packages (5):\n"
        ~ "  sparkles:base: dependency-of=sparkles:wsi\n"
        ~ "  sparkles:hue: dependent-of=sparkles:ui-tui\n"
        ~ "  sparkles:ui: from=ui\n"
        ~ "  sparkles:ui-tui: dependent-of=sparkles:ui\n"
        ~ "  sparkles:wsi [platform-skipped]: dependency-of=sparkles:ui\n"
        ~ "edges (4):\n"
        ~ "  sparkles:ui-tui -> sparkles:hue\n"
        ~ "  sparkles:wsi -> sparkles:ui\n"
        ~ "  sparkles:ui -> sparkles:ui-tui\n"
        ~ "  sparkles:base -> sparkles:wsi\n");

    const dependentsOnly = plan(graph, SelectionRequest(from: ["base"], dependents: true));
    assert(dependentsOnly.startsWith("packages (7):\n"));
    assert(dependentsOnly.canFind("  sparkles:ui: dependent-of=sparkles:wsi\n"));

    // A package pulled in by two selected neighbours records both.
    const diamond = plan(graph, SelectionRequest(from: ["fuzzy", "text-wasm"], dependencies: true));
    assert(diamond.canFind("  sparkles:base: dependency-of=sparkles:fuzzy, dependency-of=sparkles:text-wasm\n"));
}

@("build_primitives.workspace.select.selectPackages.platformSkippedSeedsAreNotEmpty")
@safe
unittest
{
    const graph = fixtureGraph();
    assert(plan(graph, SelectionRequest(from: ["wsi"])) ==
        "packages (1):\n"
        ~ "  sparkles:wsi [platform-skipped]: from=wsi\n"
        ~ "edges (0):\n");
}

@("build_primitives.workspace.select.selectPackages.cyclicGraphsNeverReachSelection")
@safe
unittest
{
    // Selection takes a validated graph: a cycle is reported by discovery.
    const cyclic = buildPackageGraph("sparkles", [
        recipe("libs/a", `name "a"
dependency "sparkles:b" path="../.."`),
        recipe("libs/b", `name "b"
dependency "sparkles:a" path="../.."`),
    ], RecipeRole.test, linux);
    assert(cyclic.hasError);
}


@("build_primitives.workspace.select.gitChangesSince.fixtureRepository")
@system
unittest
{
    import std.file : remove;
    import std.path : buildPath;
    import sparkles.build_primitives.testing : gitAvailable, TmpGitRepo;
    import sparkles.test_runner.skip : skipTest;

    if (!gitAvailable)
        return skipTest("git is not on PATH");

    auto repo = TmpGitRepo.create();
    repo.writeFile(".gitignore", "build/\n");
    repo.writeFile("dub.sdl", "name \"sparkles\"\nsubPackage \"libs/a\"\nsubPackage \"libs/b\"\n"
        ~ "subPackage \"libs/c\"\nsubPackage \"libs/old-d\"\n");
    repo.writeFile("libs/a/dub.sdl", "name \"a\"\n");
    repo.writeFile("libs/a/src/a.d", "module a;\n");
    repo.writeFile("libs/b/dub.sdl", "name \"b\"\ndependency \"sparkles:a\" path=\"../..\"\n");
    repo.writeFile("libs/b/src/b.d", "module b;\n");
    repo.writeFile("libs/c/dub.sdl", "name \"c\"\n");
    repo.writeFile("libs/old-d/dub.sdl", "name \"d\"\n");
    repo.writeFile("libs/old-d/src/d.d", "module d;\n");
    repo.writeFile("README.md", "x\n");
    repo.commitAll("base");

    // Main moves on after the branch point: its change must not count.
    assert(repo.git(["checkout", "-q", "-b", "feature"]).status == 0);
    assert(repo.git(["checkout", "-q", "main"]).status == 0);
    repo.writeFile("libs/c/src/c.d", "module c;\n");
    repo.commitAll("main moves on");
    assert(repo.git(["checkout", "-q", "feature"]).status == 0);

    // On the branch: a committed change, a moved package, a staged change,
    // an unstaged removal, an untracked file, and an ignored one.
    repo.writeFile("libs/b/src/b.d", "module b; // edited\n");
    assert(repo.git(["mv", "libs/old-d", "libs/d"]).status == 0);
    repo.writeFile("dub.sdl", "name \"sparkles\"\nsubPackage \"libs/a\"\nsubPackage \"libs/b\"\n"
        ~ "subPackage \"libs/c\"\nsubPackage \"libs/d\"\n");
    repo.commitAll("branch work");
    repo.writeFile("libs/a/src/staged.d", "module staged;\n");
    assert(repo.git(["add", "libs/a/src/staged.d"]).status == 0);
    assert(repo.git(["rm", "-q", "--cached", "README.md"]).status == 0);
    remove(repo.dir.buildPath("README.md"));
    repo.writeFile("libs/c/build/out.o", "ignored\n");
    repo.writeFile("libs/c/new.d", "module fresh;\n");

    const since = gitChangesSince(repo.dir, "main");
    assert(since.hasValue, since.hasError ? since.error.detail : null);
    assert(since.value.baseRef == "main");
    assert(since.value.changes == [
        "README.md",
        "dub.sdl",
        "libs/a/src/staged.d",
        "libs/b/src/b.d",
        "libs/c/new.d",
        "libs/d/dub.sdl",
        "libs/d/src/d.d",
        "libs/old-d/dub.sdl",
        "libs/old-d/src/d.d",
    ], "unexpected changes");
}

/// The planner end to end on a fixture repository: `--from c --since main
/// --dependents` resolves each package's test root and prints a
/// deterministic plan.
@("build_primitives.workspace.select.planPackages.fixtureRepository")
@system
unittest
{
    import std.array : appender;
    import sparkles.build_primitives.resolve.platform : BuildPlatform;
    import sparkles.build_primitives.testing : gitAvailable, TmpGitRepo;
    import sparkles.test_runner.skip : skipTest;

    if (!gitAvailable)
        return skipTest("git is not on PATH");

    auto repo = TmpGitRepo.create();
    repo.writeFile("dub.sdl", "name \"sparkles\"\nsubPackage \"libs/c\"\nsubPackage \"libs/a\"\n"
        ~ "subPackage \"libs/b\"\n");
    repo.writeFile("libs/a/dub.sdl", "name \"a\"\n");
    repo.writeFile("libs/b/dub.sdl", "name \"b\"\nconfiguration \"library\" {\n}\nconfiguration \"unittest\" {\n"
        ~ "    dependency \"sparkles:a\" path=\"../..\"\n}\n");
    repo.writeFile("libs/c/dub.sdl", "name \"c\"\nplatforms \"windows\"\n");
    repo.writeFile("libs/b/src/b.d", "module b;\n");
    repo.commitAll("base");
    assert(repo.git(["checkout", "-q", "-b", "feature"]).status == 0);
    repo.writeFile("libs/a/src/a.d", "module a;\n");

    auto options = FocusOptions(from: ["c"], since: true, sinceRef: "main", dependents: true);
    options.platform = BuildPlatform(linux, ["x86_64"], "ldc", "ldc2", 2111, "1.41.0");
    auto planned = planPackages(repo.dir, RecipeRole.test, options, linux);
    assert(planned.hasValue, planned.hasError ? planned.error.detail : null);
    auto w = appender!string;
    writeSelectionPlan(w, planned.value.selection);
    // b's test root depends on a, so a's new module is its input too.
    assert(w[] ==
        "packages (3):\n"
        ~ "  sparkles:a: changed=libs/a/src/a.d\n"
        ~ "  sparkles:b: changed=libs/a/src/a.d\n"
        ~ "  sparkles:c [platform-skipped]: from=c\n"
        ~ "edges (1):\n"
        ~ "  sparkles:a -> sparkles:b\n", w[]);
    foreach (ref r; planned.value.requests)
        assert(r.unresolved is null, r.unresolved);

    // The root recipe is a workspace input: a change to it seeds every
    // request.
    repo.writeFile("dub.sdl", "name \"sparkles\"\nsubPackage \"libs/c\"\nsubPackage \"libs/a\"\n"
        ~ "subPackage \"libs/b\"\n// edited\n");
    auto all = planPackages(repo.dir, RecipeRole.test, FocusOptions(since: true, sinceRef: "main",
        platform: options.platform), linux);
    auto allPlan = appender!string;
    writeSelectionPlan(allPlan, all.value.selection);
    {
        import std.conv : text;

        allPlan.put(text("changes: ", all.value.since.changes,
            "\nstatus: ", repo.git(["status", "--porcelain"]).output));
    }
    assert(all.value.selection.packages.length == 3, allPlan[]);
    assert(all.value.selection.packages[1].reasons[$ - 1] == SelectionReason(ReasonKind.workspaceInput, "dub.sdl"));

    // `build` reads the default configuration: b's edge to a is gone.
    const built = planPackages(repo.dir, RecipeRole.build, FocusOptions(from: ["c"], dependents: true), linux);
    assert(built.value.selection.edges.length == 0);
    assert(built.value.selection.packages.length == 1);

    const unmatched = FocusOptions(from: ["zz"]);
    assert(planPackages(repo.dir, RecipeRole.test, unmatched, linux).error
        == SelectionError(SelectionErrorKind.unmatchedSelector, "zz"));
}

@("build_primitives.workspace.select.gitChangesSince.indexOnlyAndUntrackedStates")
@system
unittest
{
    import std.file : remove;
    import std.path : buildPath;
    import sparkles.build_primitives.testing : gitAvailable, TmpGitRepo;
    import sparkles.test_runner.skip : skipTest;

    if (!gitAvailable)
        return skipTest("git is not on PATH");

    auto repo = TmpGitRepo.create();
    repo.writeFile("dub.sdl", "name \"sparkles\"\n");
    repo.writeFile("kept.d", "module kept;\n");
    repo.commitAll("base");

    // Staged, then deleted from the worktree: only the index has it.
    repo.writeFile("staged.d", "module staged;\n");
    assert(repo.git(["add", "staged.d"]).status == 0);
    remove(repo.dir.buildPath("staged.d"));
    // Untracked again by `git rm --cached`, but still on disk.
    assert(repo.git(["rm", "-q", "--cached", "kept.d"]).status == 0);

    const since = gitChangesSince(repo.dir, "HEAD");
    assert(since.hasValue, since.hasError ? since.error.detail : null);
    assert(since.value.changes == ["kept.d", "staged.d"],
        "one entry per path, whether or not the worktree has it");
}


@("build_primitives.workspace.select.gitChangesSince.defaultBaseAndErrors")
@system
unittest
{
    import sparkles.build_primitives.testing : gitAvailable, TmpGitRepo;
    import sparkles.test_runner.skip : skipTest;

    if (!gitAvailable)
        return skipTest("git is not on PATH");

    auto repo = TmpGitRepo.create();
    repo.writeFile("dub.sdl", "name \"sparkles\"\n");
    repo.commitAll("base");

    // No upstream and no origin/main.
    assert(gitChangesSince(repo.dir, null).error.kind == SelectionErrorKind.baseUnresolved);
    assert(gitChangesSince(repo.dir, "no-such-ref").error.kind == SelectionErrorKind.baseUnresolved);

    // An `origin/main` ref is the fallback base.
    const head = repo.git(["rev-parse", "HEAD"]).output;
    import std.string : strip;

    assert(repo.git(["update-ref", "refs/remotes/origin/main", head.strip]).status == 0);
    const fallback = gitChangesSince(repo.dir, null);
    assert(fallback.hasValue);
    assert(fallback.value.baseRef == "origin/main");
    assert(fallback.value.changes.length == 0);

    // An upstream wins over origin/main.
    assert(repo.git(["branch", "-q", "upstream-base"]).status == 0);
    assert(repo.git(["branch", "-q", "--set-upstream-to=upstream-base"]).status == 0);
    assert(gitChangesSince(repo.dir, null).value.baseRef == "upstream-base");
}
