/++
The repository's package graph ([SPEC §4.1](../../../../../../docs/specs/ci/task-dag/SPEC.md)):
every root `dub.sdl` sub-package with its stable qualified id, directory,
platforms, and the in-tree dependencies its active configuration declares.

Recipes are decoded through the `sparkles.build_primitives.dub_manifest`
schema (wired's SDLang backend); nothing here parses SDL by hand. Discovery
($(LREF discoverPackages)) is the only part that reads files; graph
construction ($(LREF buildPackageGraph)) is pure and takes parsed recipes.

Packages are sorted by id and edges by their ends' indices, so nothing depends
on associative-array or directory iteration order. The root package is
metadata, not a member: a dependency on it adds no edge.
+/
module sparkles.build_primitives.workspace.package_graph;

import std.algorithm.searching : startsWith;
import std.algorithm.sorting : sort;
import std.range.primitives : put;

import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.wire_names : AnyFormat, WireCase;
import sparkles.base.text.writers : writeEnumMemberName;
import sparkles.build_primitives.dub_manifest : DubConfiguration, DubManifest;

import sparkles.build_primitives.dub_manifest : platformsAllowHost;
import sparkles.build_primitives.task.graph : IndexEdge, stableTopologicalOrder;
import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;

/// A package's stable qualified name: `sparkles:base`.
struct PackageId
{
    string name; ///

    /// The part after the root's `:`: `base`.
    string shortName() const @safe pure nothrow @nogc
    {
        foreach (i, c; name)
            if (c == ':')
                return name[i + 1 .. $];
        return name;
    }

    int opCmp(const PackageId rhs) const @safe pure nothrow @nogc
        => name < rhs.name ? -1 : name > rhs.name;

    void toString(Writer)(ref Writer w) const => put(w, name);
}

/// The platforms a package builds on, as its recipe's `platforms` states
/// them (`linux`, `linux-ldc`); empty is every platform.
struct PlatformSet
{
    string[] specs; ///

    /// Whether a host described by dub OS tokens (`["linux", "posix"]`) is
    /// one of them. Only a spec's leading OS component is compared.
    bool allows(scope const(string)[] hostTokens) const @safe pure nothrow
        => platformsAllowHost(specs, hostTokens);
}

/// One package of the graph.
struct Package
{
    PackageId id;             ///
    string shortName;         /// `base`
    string path;              /// repository-relative, `/`-separated: `libs/base`
    PackageId[] dependencies; /// in-tree, sorted, without duplicates
    PlatformSet platforms;    ///
    /// The configuration whose dependencies were read; empty when the recipe
    /// declares none.
    string configuration;
}

/// Which configuration a command mode activates ([SPEC §4.1]).
@WireCase(CaseStyle.kebabCase)
enum RecipeRole
{
    /// `dub build`: the first configuration the host's platform allows.
    build,
    /// `dub test`: the `unittest` configuration if declared, else as `build`.
    test,
}

/// A parsed sub-package recipe and where it lives.
struct SubPackageRecipe
{
    string path;         /// repository-relative directory, as the root lists it
    DubManifest manifest; ///
}

/// What makes discovery fail.
@WireCase(CaseStyle.kebabCase)
enum DiscoveryErrorKind
{
    unreadableRecipe,     /// a `dub.sdl` is missing or malformed
    unnamedPackage,       /// a recipe declares no `name`
    inlineSubPackage,     /// a sub-package without a directory
    duplicateId,          /// two sub-packages share a name
    duplicatePath,        /// two sub-packages share a directory
    unknownDependency,    /// an in-tree dependency names no sub-package
    selfDependency,       /// a package depends on itself
    cycle,                /// the dependencies form a cycle
}

/**
Why discovery failed. `detail` is a path or a parser message; `ids` names
the packages involved — for a cycle, its members from the lowest, each
depending on the one before it.
*/
struct DiscoveryError
{
    DiscoveryErrorKind kind; ///
    string detail;           ///
    PackageId[] ids;         ///

    /// `cycle: sparkles:a -> sparkles:b -> sparkles:a`, `unreadable-recipe: libs/x/dub.sdl: …`.
    void toString(Writer)(ref Writer w) const
    {
        writeEnumMemberName!AnyFormat(w, kind);
        put(w, ":");
        if (detail.length)
        {
            put(w, ' ');
            put(w, detail);
        }
        foreach (i, id; ids)
        {
            put(w, i ? " -> " : " ");
            put(w, id.name);
        }
        if (kind == DiscoveryErrorKind.cycle && ids.length)
        {
            put(w, " -> ");
            put(w, ids[0].name);
        }
    }
}

/// `dependent` depends on `dependency`; both are package indices.
struct PackageEdge
{
    uint dependency; ///
    uint dependent;  ///
}

/// A validated, acyclic package graph.
struct PackageGraph
{
    private string rootName_;
    private Package[] packages_; // by id
    private PackageEdge[] edges_; // by dependent, then dependency
    private uint[] topo_;

    /// The root package's name: `sparkles`.
    string rootName() const @safe pure nothrow @nogc => rootName_;

    /// Every package, sorted by id.
    const(Package)[] packages() const return @safe pure nothrow @nogc => packages_;

    /// Every dependency edge, by dependent then dependency.
    const(PackageEdge)[] edges() const return @safe pure nothrow @nogc => edges_;

    /// Package indices, dependencies first, ties by id.
    const(uint)[] topologicalOrder() const return @safe pure nothrow @nogc => topo_;

    /// The index of `id`, or -1. A binary search.
    ptrdiff_t indexOf(const PackageId id) const @safe pure nothrow @nogc
    {
        size_t lo, hi = packages_.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (packages_[mid].id.name == id.name)
                return mid;
            if (packages_[mid].id.name < id.name)
                lo = mid + 1;
            else
                hi = mid;
        }
        return -1;
    }

    /**
    The package owning repository-relative `path`: the one whose directory
    is the longest prefix of it, at a `/` boundary. -1 when no package
    directory contains it.
    */
    ptrdiff_t owner(scope const(char)[] path) const @safe pure nothrow @nogc
        => longestPrefixOwner(packages_, path);
}

/// The index of the entry of `packages` whose `path` is the longest
/// directory prefix of `path`, or -1.
ptrdiff_t longestPrefixOwner(P)(scope const(P)[] packages, scope const(char)[] path)
{
    ptrdiff_t best = -1;
    foreach (i, ref p; packages)
        if (isUnder(path, p.path) && (best < 0 || p.path.length > packages[best].path.length))
            best = i;
    return best;
}

// Whether `path` is `dir` or lies under it.
private bool isUnder(scope const(char)[] path, scope const(char)[] dir) @safe pure nothrow @nogc
    => dir.length && path.length >= dir.length && path[0 .. dir.length] == dir
        && (path.length == dir.length || path[dir.length] == '/');

/// `path` with `\` as `/`, without `./` prefixes or a trailing `/`.
string normalizeRepoPath(string path) @safe pure nothrow
{
    bool clean = true;
    foreach (c; path)
        if (c == '\\')
            clean = false;
    string result = path;
    if (!clean)
    {
        auto copy = path.dup;
        foreach (ref c; copy)
            if (c == '\\')
                c = '/';
        result = (() @trusted => cast(string) copy)();
    }
    while (result.startsWith("./"))
        result = result[2 .. $];
    while (result.length > 1 && result[$ - 1] == '/')
        result = result[0 .. $ - 1];
    return result;
}

/**
The configuration `role` activates in `manifest`, or null when it declares
none: `unittest` for `RecipeRole.test` if present, else — like dub — the first
configuration whose `platforms` allow the host.
*/
const(DubConfiguration)* activeConfiguration(return const ref DubManifest manifest, RecipeRole role,
    scope const(string)[] hostTokens) @safe pure nothrow
{
    if (role == RecipeRole.test)
        if (auto unittest_ = manifest.configuration("unittest"))
            return unittest_;
    foreach (ref c; manifest.configurations)
        if (platformsAllowHost(c.platforms, hostTokens))
            return &c;
    return null;
}

/**
Builds the graph from parsed recipes: ids `<rootName>:<name>`, each
package's in-tree dependencies from its top level plus its active
configuration (an optional dependency that is not on by default is left
out), then validation — duplicate ids and paths, unknown dependencies,
self-dependencies, and cycles, in that order.
*/
PlanExpected!(PackageGraph, DiscoveryError) buildPackageGraph(string rootName,
    scope const(SubPackageRecipe)[] recipes, RecipeRole role, scope const(string)[] hostTokens) @safe pure nothrow
{
    alias fail = (kind, detail, ids) => planErr!PackageGraph(DiscoveryError(kind, detail, ids));

    PackageGraph graph;
    graph.rootName_ = rootName;
    const prefix = rootName ~ ":";
    foreach (ref recipe; recipes)
    {
        if (recipe.path.length == 0)
            return fail(DiscoveryErrorKind.inlineSubPackage, recipe.manifest.name, null);
        if (recipe.manifest.name.length == 0)
            return fail(DiscoveryErrorKind.unnamedPackage, recipe.path, null);

        Package p;
        p.id = PackageId(prefix ~ recipe.manifest.name);
        p.shortName = recipe.manifest.name;
        p.path = normalizeRepoPath(recipe.path);
        p.platforms = PlatformSet(recipe.manifest.platforms.dup);

        const config = activeConfiguration(recipe.manifest, role, hostTokens);
        if (config)
            p.configuration = config.name;
        void collect(scope const(typeof(recipe.manifest.dependencies)) deps)
        {
            foreach (ref d; deps)
                if (d.name.startsWith(prefix) && !(d.optional && !d.default_))
                    p.dependencies ~= PackageId(d.name);
        }
        collect(recipe.manifest.dependencies);
        if (config)
            collect(config.dependencies);
        p.dependencies.sort();
        p.dependencies = uniqueSorted(p.dependencies);
        graph.packages_ ~= p;
    }

    graph.packages_.sort!((a, b) => a.id < b.id);
    foreach (i; 1 .. graph.packages_.length)
        if (graph.packages_[i].id == graph.packages_[i - 1].id)
            return fail(DiscoveryErrorKind.duplicateId, null, [graph.packages_[i].id]);
    {
        auto byPath = graph.packages_.dup;
        byPath.sort!((a, b) => a.path < b.path);
        foreach (i; 1 .. byPath.length)
            if (byPath[i].path == byPath[i - 1].path)
                return fail(DiscoveryErrorKind.duplicatePath, byPath[i].path,
                    [byPath[i - 1].id, byPath[i].id]);
    }

    IndexEdge[] indexEdges;
    foreach (dependent, ref p; graph.packages_)
        foreach (dep; p.dependencies)
        {
            const at = graph.indexOf(dep);
            if (at < 0)
                return fail(DiscoveryErrorKind.unknownDependency, null, [p.id, dep]);
            if (at == dependent)
                return fail(DiscoveryErrorKind.selfDependency, null, [p.id]);
            graph.edges_ ~= PackageEdge(cast(uint) at, cast(uint) dependent);
            indexEdges ~= IndexEdge(cast(uint) at, cast(uint) dependent);
        }

    auto order = stableTopologicalOrder(graph.packages_.length, indexEdges);
    if (!order.acyclic)
    {
        PackageId[] ids;
        foreach (i; order.cycle)
            ids ~= graph.packages_[i].id;
        return fail(DiscoveryErrorKind.cycle, null, ids);
    }
    graph.topo_ = order.order;

    import core.lifetime : move;

    return planOk!DiscoveryError(move(graph));
}

private PackageId[] uniqueSorted(PackageId[] ids) @safe pure nothrow @nogc
{
    size_t kept;
    foreach (i, id; ids)
        if (i == 0 || id != ids[kept - 1])
            ids[kept++] = id;
    return ids[0 .. kept];
}

/**
Reads the root `dub.sdl` under `repoRoot` and every sub-package recipe it
lists, then builds the graph ($(LREF buildPackageGraph)). A bounded,
synchronous planning read ([SPEC §7]).
*/
PlanExpected!(PackageGraph, DiscoveryError) discoverPackages(string repoRoot, RecipeRole role,
    scope const(string)[] hostTokens) @safe
{
    import std.conv : text;
    import std.path : buildPath;
    import sparkles.build_primitives.dub_manifest : readDubManifest;

    alias unreadable = (path, reason) => planErr!PackageGraph(
        DiscoveryError(DiscoveryErrorKind.unreadableRecipe, path ~ ": " ~ reason));

    auto root = readDubManifest(repoRoot.buildPath("dub.sdl"));
    if (root.hasError)
        return unreadable("dub.sdl", text(root.error));
    if (root.value.name.length == 0)
        return planErr!PackageGraph(DiscoveryError(DiscoveryErrorKind.unnamedPackage, "dub.sdl"));

    SubPackageRecipe[] recipes;
    foreach (ref sub; root.value.subPackages)
    {
        if (sub.path.length == 0)
            return planErr!PackageGraph(DiscoveryError(DiscoveryErrorKind.inlineSubPackage, sub.name));
        const recipePath = normalizeRepoPath(sub.path) ~ "/dub.sdl";
        auto manifest = readDubManifest(repoRoot.buildPath(recipePath));
        if (manifest.hasError)
            return unreadable(recipePath, text(manifest.error));
        recipes ~= SubPackageRecipe(sub.path, manifest.value);
    }
    return buildPackageGraph(root.value.name, recipes, role, hostTokens);
}

version (unittest)
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import sparkles.build_primitives.dub_manifest : parseDubManifest;

    package SubPackageRecipe recipe(string path, string sdl) @safe pure
        => SubPackageRecipe(path, parseDubManifest(sdl).value);

    private string errorText(const DiscoveryError e) @safe
    {
        import std.conv : text;

        return text(e);
    }

    private enum string[] linux = ["linux", "posix"];
}

@("build_primitives.workspace.package_graph.buildPackageGraph.configurationAwareEdges")
@safe
unittest
{
    const recipes = [
        recipe("libs/ui", `name "ui"
dependency "sparkles:base" path="../.."
dependency "expected" version="~>0.4.1"
configuration "library" {
}
configuration "unittest" {
    dependency "sparkles:test-utils" path="../.."
}
`),
        recipe("libs/base", `name "base"
platforms "linux" "osx"
`),
        recipe("libs/test-utils", `name "test-utils"
dependency "sparkles:base" path="../.."
dependency "sparkles:base" path="../.."
dependency "sparkles" path="../.."
dependency "sparkles:ui" path="../.." optional=true
`),
        recipe("libs/base/text-wasm", `name "text-wasm"
configuration "wasm" {
    platforms "wasm"
    dependency "sparkles:ui" path="../../.."
}
configuration "library" {
    dependency "sparkles:base" path="../../.."
}
`),
    ];

    const tested = buildPackageGraph("sparkles", recipes, RecipeRole.test, linux).value;
    assert(tested.packages.map!(p => p.id.name).array
        == ["sparkles:base", "sparkles:test-utils", "sparkles:text-wasm", "sparkles:ui"]);
    const ui = tested.packages[tested.indexOf(PackageId("sparkles:ui"))];
    assert(ui.configuration == "unittest");
    assert(ui.dependencies.map!(d => d.name).array == ["sparkles:base", "sparkles:test-utils"]);
    // The root package and a default-off optional dependency add no edge.
    assert(tested.packages[1].dependencies.map!(d => d.name).array == ["sparkles:base"]);
    // A platform-restricted configuration is passed over, like dub does.
    assert(tested.packages[2].configuration == "library");
    assert(tested.packages[0].platforms.specs == ["linux", "osx"]);
    assert(!tested.packages[0].platforms.allows(["windows"]));
    assert(tested.topologicalOrder.map!(i => tested.packages[i].shortName).array
        == ["base", "test-utils", "text-wasm", "ui"]);

    const built = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
    const buildUi = built.packages[built.indexOf(PackageId("sparkles:ui"))];
    assert(buildUi.configuration == "library");
    assert(buildUi.dependencies.map!(d => d.name).array == ["sparkles:base"]);

    // The nested package owns its own subtree; its parent owns the rest.
    assert(tested.packages[tested.owner("libs/base/text-wasm/src/a.d")].shortName == "text-wasm");
    assert(tested.packages[tested.owner("libs/base/src/a.d")].shortName == "base");
    assert(tested.packages[tested.owner("libs/base")].shortName == "base");
    assert(tested.owner("libs/based/x.d") < 0);
    assert(tested.owner("README.md") < 0);
}

@("build_primitives.workspace.package_graph.buildPackageGraph.rejectsInvalidGraphs")
@safe
unittest
{
    static string failure(const(SubPackageRecipe)[] recipes) @safe
        => errorText(buildPackageGraph("sparkles", recipes, RecipeRole.test, linux).error);

    assert(failure([recipe("libs/a", `name "a"`), recipe("libs/b", `name "a"`)])
        == "duplicate-id: sparkles:a");
    assert(failure([recipe("libs/a", `name "a"`), recipe("libs/a/", `name "b"`)])
        == "duplicate-path: libs/a sparkles:a -> sparkles:b");
    assert(failure([recipe("libs/a", `name "a"
dependency "sparkles:gone" path="../.."`)]) == "unknown-dependency: sparkles:a -> sparkles:gone");
    assert(failure([recipe("libs/a", `name "a"
dependency "sparkles:a" path="../.."`)]) == "self-dependency: sparkles:a");
    assert(failure([recipe("libs/a", `description "x"`)]) == "unnamed-package: libs/a");
    assert(failure([
        recipe("libs/c", `name "c"
dependency "sparkles:b" path="../.."`),
        recipe("libs/b", `name "b"
dependency "sparkles:a" path="../.."`),
        recipe("libs/a", `name "a"
configuration "unittest" {
    dependency "sparkles:c" path="../.."
}`),
    ]) == "cycle: sparkles:a -> sparkles:b -> sparkles:c -> sparkles:a");
}

@("build_primitives.workspace.package_graph.discoverPackages.readsTheRepositoryRecipes")
@safe
unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create();
    tmp.writeFileAt("dub.sdl", "name \"sparkles\"\nsubPackage \"libs/b\"\nsubPackage \"./libs/a/\"\n");
    tmp.writeFileAt("libs/a/dub.sdl", "name \"a\"\n");
    tmp.writeFileAt("libs/b/dub.sdl", "name \"b\"\ndependency \"sparkles:a\" path=\"../..\"\n");

    const graph = discoverPackages(tmp.dir(), RecipeRole.test, linux).value;
    assert(graph.rootName == "sparkles");
    assert(graph.packages.map!(p => p.path).array == ["libs/a", "libs/b"]);
    assert(graph.edges == [PackageEdge(0, 1)]);

    tmp.writeFileAt("dub.sdl", "name \"sparkles\"\nsubPackage \"libs/missing\"\n");
    const missing = discoverPackages(tmp.dir(), RecipeRole.test, linux);
    assert(missing.error.kind == DiscoveryErrorKind.unreadableRecipe);
    assert(missing.error.detail.startsWith("libs/missing/dub.sdl: "));
}

/// The repository's own graph discovers and validates in both roles.
@("build_primitives.workspace.package_graph.discoverPackages.thisRepository")
@safe
unittest
{
    import std.path : buildNormalizedPath;
    import sparkles.build_primitives.dub_manifest : hostPlatformTokens;

    // This file is libs/build-primitives/src/sparkles/build_primitives/workspace/package_graph.d.
    const root = buildNormalizedPath(__FILE_FULL_PATH__, "../../../../../../..");
    foreach (role; [RecipeRole.build, RecipeRole.test])
    {
        auto graph = discoverPackages(root, role, hostPlatformTokens());
        assert(graph.hasValue, errorText(graph.error));
        assert(graph.value.indexOf(PackageId("sparkles:ci")) >= 0);
        assert(graph.value.packages[graph.value.owner("apps/ci/src/app.d")].shortName == "ci");
    }
}
