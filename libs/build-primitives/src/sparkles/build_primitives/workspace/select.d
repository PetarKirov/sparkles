/++
Focused package selection ([SPEC §4.2–4.4](../../../../../../docs/specs/ci/task-dag/SPEC.md)):
`--from` selectors, `--since` change ownership and repository-wide
invalidators, dependency and dependent closure, platform eligibility, and the
reasons each package was selected.

$(LREF selectPackages) is pure: it evaluates the selection algebra over a
$(REF PackageGraph, sparkles,build_primitives,workspace,package_graph) and a description of what
changed. $(LREF gitChangesSince) is the one part that runs git — through
`runGit`, so an inherited `GIT_DIR` cannot redirect it — and produces that
description.
+/
module sparkles.build_primitives.workspace.select;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.range.primitives : put;

import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.wire_names : AnyFormat, WireCase;
import sparkles.base.text.writers : writeEnumMemberName, writeValue;
import sparkles.build_primitives.gitignore : gitGlobMatch;

import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;
import sparkles.build_primitives.workspace.package_graph : longestPrefixOwner, normalizeRepoPath, PackageEdge,
    PackageGraph, PackageId, RecipeRole;

// ─────────────────────────────────────────────────────────────────────────────
// Repository-wide invalidators
// ─────────────────────────────────────────────────────────────────────────────

/// A path that, when changed, selects every package: a file, or a directory
/// prefix ending in `/`.
struct Invalidator
{
    string path; ///

    /// Whether repository-relative `changed` is this path or lies under it.
    bool matches(scope const(char)[] changed) const @safe pure nothrow @nogc
        => path.length && path[$ - 1] == '/' ? changed.startsWith(path) : changed == path;
}

/**
The declarative list of repository-wide inputs ([SPEC §4.3]): the root
recipe and lockfiles, the compiler and package builders, and the `ci` modules
that discover packages and construct their tasks. Anything else outside every
package selects nothing. The list grows only by editing it.
*/
immutable Invalidator[] repositoryInvalidators = [
    Invalidator("dub.sdl"),
    Invalidator("dub.selections.json"),
    Invalidator("nix/dub-lock.json"),
    Invalidator("nix/d-toolchain.nix"),
    Invalidator("nix/packages/dub-builder/"),
    Invalidator("apps/ci/src/task/"),
    Invalidator("apps/ci/src/workspace/"),
    Invalidator("apps/ci/src/commands/"),
];

/// The invalidator `path` hits, or null.
const(Invalidator)* invalidatorFor(scope const(char)[] path) @safe pure nothrow @nogc
{
    foreach (ref rule; repositoryInvalidators)
        if (rule.matches(path))
            return &rule;
    return null;
}

///
@("build_primitives.workspace.select.repositoryInvalidators.declarative")
@safe pure nothrow @nogc
unittest
{
    assert(invalidatorFor("dub.sdl"));
    assert(invalidatorFor("dub.selections.json"));
    assert(invalidatorFor("nix/dub-lock.json"));
    assert(invalidatorFor("nix/d-toolchain.nix"));
    assert(invalidatorFor("nix/packages/dub-builder/default.nix"));
    assert(invalidatorFor("apps/ci/src/workspace/select.d"));
    assert(invalidatorFor("apps/ci/src/task/graph.d"));

    // A sub-package's own recipe, other top-level files, and the rest of
    // `ci` are ordinary paths.
    assert(!invalidatorFor("libs/base/dub.sdl"));
    assert(!invalidatorFor("README.md"));
    assert(!invalidatorFor("flake.nix"));
    assert(!invalidatorFor("nix/packages/dub-builderx"));
    assert(!invalidatorFor("apps/ci/src/app.d"));
}

// ─────────────────────────────────────────────────────────────────────────────
// The selection algebra
// ─────────────────────────────────────────────────────────────────────────────

/// A path changed since the base revision.
struct ChangedPath
{
    string path;  /// repository-relative, `/`-separated
    bool deleted; /// absent from the working tree
}

/// A package as the base revision declared it: what a deleted path is also
/// resolved against.
struct BasePackage
{
    PackageId id; ///
    string path;  ///
}

/// What to select. Without `from` and `since`, every package is seeded.
struct SelectionRequest
{
    /// `--from` selectors, each a short name, qualified name, or path, or a
    /// git-style glob over any of those.
    const(string)[] from;
    /// Whether `--since` was given; `changes` and `basePackages` then
    /// describe the change set.
    bool since;
    const(ChangedPath)[] changes; ///
    const(BasePackage)[] basePackages; ///
    bool dependencies; /// `--dependencies`
    bool dependents;   /// `--dependents`
}

/// Why a package was selected.
@WireCase(CaseStyle.kebabCase)
enum ReasonKind
{
    all,          /// no selector was given
    from,         /// a `--from` selector matched; `detail` is the selector
    changed,      /// a changed path it owns; `detail` is the path
    invalidator,  /// a repository-wide input changed; `detail` is the path
    dependencyOf, /// a selected package depends on it; `detail` is that package
    dependentOf,  /// it depends on a selected package; `detail` is that package
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

/// Whether `selector` is a glob rather than a literal.
bool isGlob(scope const(char)[] selector) @safe pure nothrow @nogc
{
    foreach (c; selector)
        if (c == '*' || c == '?' || c == '\\')
            return true;
    return false;
}

/**
Evaluates [SPEC §4.4]'s algebra: seed from `--from` and/or `--since` (their
union), or every package; add the transitive dependency and/or dependent
closure of the $(I seed) — both closures computed from the original seed and
unioned, so neither expands the other's result; mark platform-ineligible
packages skipped; sort by id and induce the edges among the selected.

Errors: a selector (literal or glob) that matches nothing, and a seed that is
empty — a misspelled selector or an empty change set never becomes a green
no-op. Selected packages that are all platform-skipped are not an error.
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
        foreach (ref change; request.changes)
        {
            if (invalidatorFor(change.path))
            {
                foreach (i; 0 .. count)
                    seed(i, ReasonKind.invalidator, change.path);
                continue;
            }
            const current = graph.owner(change.path);
            if (current >= 0)
                seed(current, ReasonKind.changed, change.path);
            if (!change.deleted)
                continue;
            // A deleted path also counts for the package that owned it at
            // the base revision, if that package still exists.
            const based = longestPrefixOwner(request.basePackages, change.path);
            if (based < 0)
                continue;
            const now = graph.indexOf(request.basePackages[based].id);
            if (now >= 0 && now != current)
                seed(now, ReasonKind.changed, change.path);
        }

    bool any;
    foreach (s; seeded)
        any |= s;
    if (!any)
        return planErr!Selection(SelectionError(SelectionErrorKind.emptySelection,
            request.since ? "no package owns a path changed since the base revision"
                : "no package was seeded"));

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
    string baseRef;              /// the revision named or resolved
    string mergeBase;            /// `merge-base(baseRef, HEAD)`
    ChangedPath[] changes;       /// sorted by path
    BasePackage[] basePackages;  /// the packages the merge base declared
}

/**
The paths changed from `merge-base(sinceRef, HEAD)` through the working tree
— committed, staged, unstaged, and untracked-but-not-ignored — and the
packages the merge base declared.

A null `sinceRef` resolves the current branch's upstream, else `origin/main`;
neither existing is `SelectionErrorKind.baseUnresolved`. Renames count as a
deletion plus an addition. Every git call goes through `runGit`.
*/
PlanExpected!(SinceChanges, SelectionError) gitChangesSince(string repoRoot, string sinceRef) @safe
{
    import std.string : strip;
    import sparkles.build_primitives.dub_manifest : parseDubManifest;
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

        const diff = git(["diff", "--name-status", "-z", "--no-renames", since.mergeBase, "--"]);
        if (diff.status != 0)
            return fail(SelectionErrorKind.gitFailed, "git diff: " ~ diff.output.strip);
        const diffFields = fields(diff.output);
        for (size_t i = 0; i + 1 < diffFields.length; i += 2)
            since.changes ~= ChangedPath(diffFields[i + 1], diffFields[i].startsWith("D"));

        const untracked = git(["ls-files", "--others", "--exclude-standard", "-z"]);
        if (untracked.status != 0)
            return fail(SelectionErrorKind.gitFailed, "git ls-files: " ~ untracked.output.strip);
        foreach (path; fields(untracked.output))
            since.changes ~= ChangedPath(path);

        // The base revision's package map, for deleted paths. A recipe the
        // base cannot show or parse simply contributes no package.
        const rootRecipe = git(["show", since.mergeBase ~ ":dub.sdl"]);
        if (rootRecipe.status == 0)
        {
            auto root = parseDubManifest(rootRecipe.output);
            if (root.hasValue && root.value.name.length)
                foreach (ref sub; root.value.subPackages)
                {
                    if (!sub.path.length)
                        continue;
                    const path = normalizeRepoPath(sub.path);
                    const recipe = git(["show", since.mergeBase ~ ":" ~ path ~ "/dub.sdl"]);
                    if (recipe.status != 0)
                        continue;
                    auto manifest = parseDubManifest(recipe.output);
                    if (manifest.hasValue && manifest.value.name.length)
                        since.basePackages ~= BasePackage(
                            PackageId(root.value.name ~ ":" ~ manifest.value.name), path);
                }
        }
    }
    catch (Exception e)
        return fail(SelectionErrorKind.gitFailed, e.msg);

    since.changes.sort!((a, b) => a.path < b.path);

    import core.lifetime : move;

    return planOk!SelectionError(move(since));
}
// ─────────────────────────────────────────────────────────────────────────────
// The focused-selection planner
// ─────────────────────────────────────────────────────────────────────────────

/// `ci test`'s focused-selection options ([SPEC §2.1]).
struct FocusOptions
{
    const(string)[] from; /// `--from`
    bool since;           /// `--since` given
    string sinceRef;      /// its value; null resolves the upstream, else `origin/main`
    bool dependencies;    /// `--dependencies`
    bool dependents;      /// `--dependents`
}

/// A discovered graph and the selection made from it.
struct PackagePlan
{
    PackageGraph graph;  ///
    Selection selection; ///
    /// What `--since` found; `baseRef` is empty without `--since`.
    SinceChanges since;
}

/**
Discovers the package graph under `repoRoot` for `role`, queries git when
`--since` is given, and selects ([SPEC §4.4] steps 1–10). Side-effect free
apart from reading recipes and running read-only git queries, so a dry run
may call it.
*/
PlanExpected!(PackagePlan, SelectionError) planPackages(string repoRoot, RecipeRole role,
    const ref FocusOptions options, scope const(string)[] hostTokens) @safe
{
    import std.conv : text;
    import core.lifetime : move;
    import sparkles.build_primitives.workspace.package_graph : discoverPackages;

    PackagePlan plan;
    auto graph = discoverPackages(repoRoot, role, hostTokens);
    if (graph.hasError)
        return planErr!PackagePlan(SelectionError(SelectionErrorKind.discoveryFailed, text(graph.error)));
    plan.graph = move(graph.value);

    if (options.since)
    {
        auto since = gitChangesSince(repoRoot, options.sinceRef);
        if (since.hasError)
            return planErr!PackagePlan(since.error);
        plan.since = move(since.value);
    }
    const request = SelectionRequest(options.from, options.since, plan.since.changes,
        plan.since.basePackages, options.dependencies, options.dependents);
    auto selection = selectPackages(plan.graph, request, hostTokens);
    if (selection.hasError)
        return planErr!PackagePlan(selection.error);
    plan.selection = move(selection.value);
    return planOk!SelectionError(move(plan));
}


// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.build_primitives.workspace.package_graph : buildPackageGraph, recipe;

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

    private string plan(const ref PackageGraph graph, SelectionRequest request) @safe
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
    // A `--since` whose changes no package owns seeds nothing.
    assert(plan(graph, SelectionRequest(since: true, changes: [ChangedPath("README.md")]))
        == "empty-selection: no package owns a path changed since the base revision");
    assert(plan(graph, SelectionRequest(since: true))
        == "empty-selection: no package owns a path changed since the base revision");
}

@("build_primitives.workspace.select.selectPackages.sinceOwnershipDeletionsAndInvalidators")
@safe
unittest
{
    const graph = fixtureGraph();
    // The longest prefix owns a path; a path outside every package selects
    // nothing; `--from` unions with `--since`.
    assert(plan(graph, SelectionRequest(from: ["fuzzy"], since: true, changes: [
        ChangedPath("libs/base/text-wasm/src/a.d"),
        ChangedPath("libs/base/src/b.d"),
        ChangedPath("docs/index.md"),
    ])) ==
        "packages (3):\n"
        ~ "  sparkles:base: changed=libs/base/src/b.d\n"
        ~ "  sparkles:fuzzy: from=fuzzy\n"
        ~ "  sparkles:text-wasm: changed=libs/base/text-wasm/src/a.d\n"
        ~ "edges (2):\n"
        ~ "  sparkles:base -> sparkles:fuzzy\n"
        ~ "  sparkles:base -> sparkles:text-wasm\n");

    // A deleted path counts for its current owner and for the package that
    // owned it at the base — here `ui`, which used to live at `libs/old-ui`.
    assert(plan(graph, SelectionRequest(since: true,
        changes: [ChangedPath("libs/old-ui/src/x.d", deleted: true),
            ChangedPath("libs/base/text-wasm/gone.d", deleted: true)],
        basePackages: [BasePackage(PackageId("sparkles:ui"), "libs/old-ui"),
            BasePackage(PackageId("sparkles:base"), "libs/base"),
            BasePackage(PackageId("sparkles:text-wasm"), "libs/base/text-wasm")])) ==
        "packages (2):\n"
        ~ "  sparkles:text-wasm: changed=libs/base/text-wasm/gone.d\n"
        ~ "  sparkles:ui: changed=libs/old-ui/src/x.d\n"
        ~ "edges (0):\n");

    // A repository-wide input selects everything.
    const all = plan(graph, SelectionRequest(since: true, changes: [ChangedPath("dub.selections.json")]));
    assert(all.startsWith("packages (7):\n  sparkles:base: invalidator=dub.selections.json\n"));
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
    import sparkles.build_primitives.testing : gitAvailable, TmpGitRepo;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.build_primitives.workspace.package_graph : discoverPackages;

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
    // an unstaged deletion, an untracked file, and an ignored one.
    repo.writeFile("libs/b/src/b.d", "module b; // edited\n");
    assert(repo.git(["mv", "libs/old-d", "libs/d"]).status == 0);
    repo.writeFile("dub.sdl", "name \"sparkles\"\nsubPackage \"libs/a\"\nsubPackage \"libs/b\"\n"
        ~ "subPackage \"libs/c\"\nsubPackage \"libs/d\"\n");
    repo.commitAll("branch work");
    repo.writeFile("libs/a/src/staged.d", "module staged;\n");
    assert(repo.git(["add", "libs/a/src/staged.d"]).status == 0);
    assert(repo.git(["rm", "-q", "--cached", "README.md"]).status == 0);
    import std.file : remove;
    import std.path : buildPath;

    remove(repo.dir.buildPath("README.md"));
    repo.writeFile("libs/c/build/out.o", "ignored\n");
    repo.writeFile("libs/c/new.d", "module fresh;\n");

    const since = gitChangesSince(repo.dir, "main");
    assert(since.hasValue, since.hasError ? since.error.detail : null);
    assert(since.value.baseRef == "main");
    import std.algorithm.iteration : map;
    import std.array : array;

    assert(since.value.changes == [
        ChangedPath("README.md", deleted: true),
        ChangedPath("dub.sdl"),
        ChangedPath("libs/a/src/staged.d"),
        ChangedPath("libs/b/src/b.d"),
        ChangedPath("libs/c/new.d"),
        ChangedPath("libs/d/dub.sdl"),
        ChangedPath("libs/d/src/d.d"),
        ChangedPath("libs/old-d/dub.sdl", deleted: true),
        ChangedPath("libs/old-d/src/d.d", deleted: true),
    ], "unexpected changes");
    assert(since.value.basePackages.map!(p => p.id.name ~ "@" ~ p.path).array
        == ["sparkles:a@libs/a", "sparkles:b@libs/b", "sparkles:c@libs/c", "sparkles:d@libs/old-d"]);

    // The root recipe changed, so this branch selects everything; without
    // that invalidator, ownership alone decides.
    auto graph = discoverPackages(repo.dir, RecipeRole.test, linux).value;
    auto request = SelectionRequest(since: true, changes: since.value.changes,
        basePackages: since.value.basePackages);
    auto all = selectPackages(graph, request, linux).value;
    assert(all.packages.length == 4);
    assert(all.packages[0].reasons[$ - 1] == SelectionReason(ReasonKind.invalidator, "dub.sdl"));

    auto owned = since.value.changes.dup;
    owned = owned[0 .. 1] ~ owned[2 .. $];
    request.changes = owned;
    const focused = plan(graph, request);
    assert(focused ==
        "packages (4):\n"
        ~ "  sparkles:a: changed=libs/a/src/staged.d\n"
        ~ "  sparkles:b: changed=libs/b/src/b.d\n"
        ~ "  sparkles:c: changed=libs/c/new.d\n"
        ~ "  sparkles:d: changed=libs/d/dub.sdl, changed=libs/d/src/d.d,"
        ~ " changed=libs/old-d/dub.sdl, changed=libs/old-d/src/d.d\n"
        ~ "edges (1):\n"
        ~ "  sparkles:a -> sparkles:b\n", focused);
}

/// The planner end to end on a fixture repository: `--from c --since main
/// --dependents` prints a deterministic plan.
@("build_primitives.workspace.select.planPackages.fixtureRepository")
@system
unittest
{
    import std.array : appender;
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
    repo.commitAll("base");
    assert(repo.git(["checkout", "-q", "-b", "feature"]).status == 0);
    repo.writeFile("libs/a/src/a.d", "module a;\n");

    const options = FocusOptions(from: ["c"], since: true, sinceRef: "main", dependents: true);
    auto planned = planPackages(repo.dir, RecipeRole.test, options, linux);
    assert(planned.hasValue, planned.hasError ? planned.error.detail : null);
    auto w = appender!string;
    writeSelectionPlan(w, planned.value.selection);
    assert(w[] ==
        "packages (3):\n"
        ~ "  sparkles:a: changed=libs/a/src/a.d\n"
        ~ "  sparkles:b: dependent-of=sparkles:a\n"
        ~ "  sparkles:c [platform-skipped]: from=c\n"
        ~ "edges (1):\n"
        ~ "  sparkles:a -> sparkles:b\n", w[]);

    // `build` reads the default configuration: b's edge to a is gone.
    auto built = planPackages(repo.dir, RecipeRole.build, options, linux);
    assert(built.value.selection.edges.length == 0);
    assert(built.value.selection.packages.length == 2);

    const unmatched = FocusOptions(from: ["zz"]);
    assert(planPackages(repo.dir, RecipeRole.test, unmatched, linux).error
        == SelectionError(SelectionErrorKind.unmatchedSelector, "zz"));
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
