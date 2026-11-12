/++
The packages' input sets: for every package of a
$(REF PackageGraph, sparkles,build_primitives,workspace,package_graph), the
fileset of the files its own compile can read, derived from its recipe
([design](../../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
BGW3–BGW6).

A package's directory says where it lives. Its input set says what it reads:
its recipe, the modules under its source paths, every file under its import
and string-import roots, and the files it names one by one, wherever the
recipe points. An import root is taken whole, as the build graph's keys take
it (BGK6): what a compile may read there is not decided by a file's name. The
two differ in both directions. A `README.md` beside a recipe is in the
directory and in no input set; a source path of `../harness/src` is in the
input set and in another package's directory.

Every set lives in one arena, written relative to the repository root. A
package's start roots, the directories its set lies beneath, index it: a
query for the packages claiming a path ($(LREF PackageInputSets.eachClaimant))
evaluates only those with a root above the path, and the union of several
packages' sets plans the directories a watch of them starts from
($(LREF PackageInputSets.startRoots)).

Construction is pure and total: it reads no file. A recipe path that names a
variable, or leaves the repository, is no part of any set and is reported
($(LREF PackageInputSets.opaque)), never guessed at. Where dub probes for a
default directory (`source/`, `src/`, `views/`), the set holds every candidate:
a directory that does not exist contributes no file, and one created later is
already covered.

A prototype of the seam: it reads the role's active configuration as
$(REF activeConfiguration, sparkles,build_primitives,workspace,package_graph)
does, not dub's per-request configuration choice.
+/
module sparkles.build_primitives.workspace.input_sets;

import sparkles.build_primitives.dub_manifest : DubPlatformValues, platformsAllowHost;
import sparkles.build_primitives.fileset.listing : escapeGlob;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.plan : Plan, plan;
import sparkles.build_primitives.fileset.value : EntryFacts, Fileset, FilesetEvaluator, Filesets;
import sparkles.build_primitives.workspace.package_graph : activeConfiguration, normalizeRepoPath,
    PackageGraph, RecipeRole, SubPackageRecipe;

/// Why a recipe path is part of no input set.
enum OpaqueReason : ubyte
{
    variable,          /// it names a variable other than a leading `$PACKAGE_DIR`
    outsideRepository, /// it is absolute, or climbs above the repository root
    notAPattern,       /// it is no fileset pattern
    noRecipe,          /// the package's recipe is not among those given
}

/// A recipe path that became part of no input set.
struct OpaqueDirective
{
    uint package_;       /// the package's index in the graph
    string directive;    /// `sourcePaths`
    string value;        /// as the recipe writes it
    OpaqueReason reason; ///
}

/**
The input sets of every package of one graph, in one arena. Move-only, like
the arena. Indices are the graph's package indices.
*/
struct PackageInputSets
{
    @disable this(this);

    private Filesets sets_;
    private Fileset[] inputs_;
    private Fileset[] sources_;
    private Fileset[] whole_;   // inputs and sources: what one package's evaluator judges
    private string[][] roots_;  // each package's start roots: the index a query consults first
    private FilesetEvaluator[] judges_; // made when a package is first a candidate
    private bool[] judging_;
    private Fileset all_;

    /// The recipe paths no set could hold, by package then recipe order.
    OpaqueDirective[] opaque;

    /// The number of packages.
    size_t length() const @safe pure nothrow @nogc => inputs_.length;

    /// The arena every set is built in; patterns are relative to the
    /// repository root.
    ref const(Filesets) sets() const return @safe pure nothrow @nogc => sets_;

    /// The files package `index`'s own compile can read: its recipe, its
    /// source and import roots' modules, its string imports and the files it
    /// names.
    Fileset inputs(size_t index) const @safe pure nothrow @nogc => inputs_[index];

    /// The modules package `index` compiles: its source roots' modules and
    /// named source files, without the excluded ones. A subset of `inputs`.
    Fileset sources(size_t index) const @safe pure nothrow @nogc => sources_[index];

    /// The union of every package's input set.
    Fileset all() const @safe pure nothrow @nogc => all_;

    /**
    Calls `sink(index)` for each package whose input set holds the
    repository-relative `path`, in index order. Reads no file: a path need
    not exist.

    The start roots are the index: only a package with a root above `path` is
    evaluated, so a query costs what the few packages reaching that directory
    cost, not what the repository does.
    */
    void eachClaimant(Sink)(scope const(char)[] path, scope Sink sink)
    {
        foreach (i, f; inputs_)
            if (reaches(i, path) && judge(i, path).selects(f))
                sink(cast(uint) i);
    }

    /// Whether package `index` compiles the module at `path`.
    bool compiles(size_t index, scope const(char)[] path) @safe nothrow
        => reaches(index, path) && judge(index, path).selects(sources_[index]);

    /// The directories package `index`'s input set lies beneath, in path
    /// order: where its resolution starts.
    const(string)[] rootsOf(size_t index) const return @safe pure nothrow @nogc => roots_[index];

    // Whether a start root of package `index` is `path` or lies above it.
    private bool reaches(size_t index, scope const(char)[] path) const @safe pure nothrow @nogc
    {
        foreach (root; roots_[index])
            if (root.length == 0 || (path.length >= root.length && path[0 .. root.length] == root
                    && (path.length == root.length || path[root.length] == '/')))
                return true;
        return false;
    }

    // Package `index`'s evaluator, having judged `path` against its input
    // set and its sources in one walk.
    private ref FilesetEvaluator judge(size_t index, scope const(char)[] path) return @safe nothrow
    {
        if (!judging_[index])
        {
            judges_[index] = FilesetEvaluator(sets_, whole_[index]);
            judging_[index] = true;
        }
        judges_[index].judge(sets_, path, EntryFacts.init);
        return judges_[index];
    }

    /**
    The directories a resolution, or a watch, of `packages`' input sets
    starts from: no one beneath another, in path order. Adds the union to
    the arena.
    */
    Plan startRoots(scope const(uint)[] packages) @safe nothrow @nogc
    {
        Fileset u = sets_.nothing;
        foreach (p; packages)
            u = sets_.union_(u, inputs_[p]);
        return plan(sets_, u);
    }
}

/**
Builds the input sets of `graph`'s packages from the `recipes` it was built
from, for the configuration `role` activates on a host described by
`hostTokens`. Pure and total; see the module's notes on what a set holds.
*/
PackageInputSets packageInputSets(const ref PackageGraph graph, scope const(SubPackageRecipe)[] recipes,
    RecipeRole role, scope const(string)[] hostTokens) @safe nothrow
{
    PackageInputSets result;
    result.sets_ = Filesets(CasePolicy.sensitive);
    const count = graph.packages.length;
    result.inputs_ = new Fileset[count];
    result.sources_ = new Fileset[count];
    result.whole_ = new Fileset[count];
    result.roots_ = new string[][count];
    result.judges_ = new FilesetEvaluator[count];
    result.judging_ = new bool[count];

    Fileset allInputs = result.sets_.nothing;
    foreach (i, ref p; graph.packages)
    {
        auto b = Builder(&result.sets_, &result.opaque, cast(uint) i, p.path);
        b.begin();
        bool found;
        foreach (ref r; recipes)
        {
            if (normalizeRepoPath(r.path) != p.path)
                continue;
            found = true;
            b.top(r.manifest);
            b.block(r.manifest, hostTokens);
            if (const config = activeConfiguration(r.manifest, role, hostTokens))
                b.block(*config, hostTokens);
            break;
        }
        // Nothing is known of what it reads: say so, not an empty set.
        if (!found)
            result.opaque ~= OpaqueDirective(cast(uint) i, "recipe", p.path, OpaqueReason.noRecipe);
        result.inputs_[i] = b.inputs();
        result.sources_[i] = b.sources();
        result.whole_[i] = result.sets_.union_(result.inputs_[i], result.sources_[i]);
        auto roots = plan(result.sets_, result.inputs_[i]);
        foreach (k; 0 .. roots.length)
            result.roots_[i] ~= roots[k].idup;
        allInputs = result.sets_.union_(allInputs, result.inputs_[i]);
    }
    result.all_ = allInputs;
    return result;
}

// One package's sets under construction.
private struct Builder
{
    Filesets* sets;
    OpaqueDirective[]* opaque;
    uint index;
    string directory; // repository-relative

    Fileset compiled, excluded, read;

    void begin() scope @safe nothrow
    {
        compiled = sets.nothing;
        excluded = sets.nothing;
        // The recipe itself.
        read = literal("dub.sdl", "dub.sdl");
    }

    Fileset inputs() scope @safe nothrow @nogc => sets.union_(read, compiled);

    Fileset sources() scope @safe nothrow @nogc => sets.difference(compiled, excluded);

    // dub's defaults for a recipe that is silent at its top level
    // (`Package.fillWithDefaults`): every candidate, with no probe.
    void top(Recipe)(const ref Recipe recipe) scope @safe nothrow
    {
        if (!statedUnqualified(recipe.sourcePaths))
            foreach (candidate; ["source", "src"])
                compiled = sets.union_(compiled, under("sourcePaths", candidate, ["*.d"]));
        if (!statedUnqualified(recipe.importPaths))
            foreach (candidate; ["source", "src"])
                read = sets.union_(read, root("importPaths", candidate));
        if (!statedUnqualified(recipe.stringImportPaths))
            read = sets.union_(read, root("stringImportPaths", "views"));
    }

    // What one block of settings reaches: the recipe's top level, or a
    // configuration.
    void block(Block)(const ref Block settings, scope const(string)[] hostTokens) scope @safe nothrow
    {
        void each(string directive, scope const(DubPlatformValues)[] entries,
            scope void delegate(string) @safe nothrow add)
        {
            foreach (ref entry; entries)
                if (entry.platform.length == 0 || platformsAllowHost([entry.platform], hostTokens))
                    foreach (value; entry.values)
                        add(value);
        }

        each("sourcePaths", settings.sourcePaths,
            v => cast(void)(compiled = sets.union_(compiled, under("sourcePaths", v, ["*.d"]))));
        // A C source includes from its own directory, and the preprocessor
        // reports no lookup that failed there: the root is read whole.
        each("cSourcePaths", settings.cSourcePaths, (v) {
            compiled = sets.union_(compiled, under("cSourcePaths", v, ["*.c", "*.i"]));
            read = sets.union_(read, root("cSourcePaths", v));
        });
        each("sourceFiles", settings.sourceFiles, (v) {
            compiled = sets.union_(compiled, pattern("sourceFiles", v));
            if (isCSource(v))
                read = sets.union_(read, root("sourceFiles", directoryOf(v)));
        });
        each("injectSourceFiles", settings.injectSourceFiles,
            v => cast(void)(compiled = sets.union_(compiled, pattern("injectSourceFiles", v))));
        each("excludedSourceFiles", settings.excludedSourceFiles,
            v => cast(void)(excluded = sets.union_(excluded, pattern("excludedSourceFiles", v))));
        each("importPaths", settings.importPaths,
            v => cast(void)(read = sets.union_(read, root("importPaths", v))));
        each("cImportPaths", settings.cImportPaths,
            v => cast(void)(read = sets.union_(read, root("cImportPaths", v))));
        each("stringImportPaths", settings.stringImportPaths,
            v => cast(void)(read = sets.union_(read, root("stringImportPaths", v))));
        each("extraDependencyFiles", settings.extraDependencyFiles,
            v => cast(void)(read = sets.union_(read, pattern("extraDependencyFiles", v))));
        each("copyFiles", settings.copyFiles,
            v => cast(void)(read = sets.union_(read, pattern("copyFiles", v))));
        if (settings.mainSourceFile.length)
            compiled = sets.union_(compiled, literal("mainSourceFile", settings.mainSourceFile));
    }

    // The modules beneath the recipe directory `written`: the files whose names
    // match one of `names`, without those dub skips, any with a hidden component
    // beneath that directory.
    Fileset under(string directive, string written, scope const(string)[] names) scope @safe nothrow
    {
        string dir;
        if (!place(directive, written, dir))
            return sets.nothing;
        const base = dir.length ? "/" ~ escapeGlob(dir) : "";
        Fileset found = sets.nothing;
        foreach (name; names)
            found = sets.union_(found, glob(directive, written, base ~ "/**/" ~ name));
        return sets.difference(found, glob(directive, written, base ~ "/**/.*"));
    }

    // Every file beneath the recipe directory `written`: a root a compile
    // searches, taken whole.
    Fileset root(string directive, string written) scope @safe nothrow
    {
        string dir;
        if (!place(directive, written, dir))
            return sets.nothing;
        return glob(directive, written, dir.length ? "/" ~ escapeGlob(dir) ~ "/**" : "/**");
    }

    // The one file `written` names.
    Fileset literal(string directive, string written) scope @safe nothrow
    {
        string path;
        if (!place(directive, written, path))
            return sets.nothing;
        return glob(directive, written, "/" ~ escapeGlob(path));
    }

    // The files the glob `written` selects, anchored at the package. The
    // package's own directory is matched literally; a glob that climbs out
    // of it is taken as written.
    Fileset pattern(string directive, string written) scope @safe nothrow
    {
        string path;
        if (!place(directive, written, path))
            return sets.nothing;
        const inside = directory.length && path.length > directory.length
            && path[0 .. directory.length] == directory && path[directory.length] == '/';
        return glob(directive, written,
            inside ? "/" ~ escapeGlob(directory) ~ path[directory.length .. $] : "/" ~ path);
    }

    Fileset glob(string directive, string written, string text) scope @safe nothrow
    {
        auto g = sets.glob(text);
        if (g.hasError)
        {
            *opaque ~= OpaqueDirective(index, directive, written, OpaqueReason.notAPattern);
            return sets.nothing;
        }
        return g.value;
    }

    // `written`, a path relative to the package, as one relative to the
    // repository root; false, and a report, when it has none.
    bool place(string directive, string written, out string placed) scope @safe nothrow
    {
        OpaqueReason why;
        if (repositoryPath(directory, written, placed, why))
            return true;
        *opaque ~= OpaqueDirective(index, directive, written, why);
        return false;
    }
}

// Whether `path` names a C source: `.c` or `.i`.
private bool isCSource(scope const(char)[] path) @safe pure nothrow @nogc
    => path.length > 2 && (path[$ - 2 .. $] == ".c" || path[$ - 2 .. $] == ".i");

// The directory part of the recipe path `path`; `.` when it has none.
private string directoryOf(string path) @safe pure nothrow @nogc
{
    foreach_reverse (i, c; path)
        if (c == '/' || c == '\\')
            return path[0 .. i];
    return ".";
}

// Whether `entries` holds an occurrence with no platform: what dub's
// `"" in template.sourcePaths` asks.
private bool statedUnqualified(scope const(DubPlatformValues)[] entries) @safe pure nothrow @nogc
{
    foreach (ref entry; entries)
        if (entry.platform.length == 0)
            return true;
    return false;
}

/**
`written`, a path a recipe in `packageDirectory` states, as a normalized path
relative to the repository root: `.` and `..` resolved, `\` as `/`, no
trailing `/`. A leading `$PACKAGE_DIR` is the package's directory. False, with
the reason, for a path that names another variable, is absolute, or climbs
above the root.
*/
bool repositoryPath(scope const(char)[] packageDirectory, scope const(char)[] written, out string placed,
    out OpaqueReason why) @safe pure nothrow
{
    enum own = "$PACKAGE_DIR";
    // The variable ends where a name would: `$PACKAGE_DIRS` is another one.
    static bool endsName(scope const(char)[] rest) @safe pure nothrow @nogc
        => rest.length == 0 || rest[0] == '/' || rest[0] == '\\';
    if (written.length >= own.length && written[0 .. own.length] == own && endsName(written[own.length .. $]))
    {
        written = written[own.length .. $];
        while (written.length && (written[0] == '/' || written[0] == '\\'))
            written = written[1 .. $];
    }
    else if ((written.length && (written[0] == '/' || written[0] == '\\'))
        || (written.length > 1 && written[1] == ':')) // a drive: `C:/…`
    {
        why = OpaqueReason.outsideRepository;
        return false;
    }
    foreach (c; written)
        if (c == '$')
        {
            why = OpaqueReason.variable;
            return false;
        }

    // The path so far; `..` cuts its last component.
    char[] path;
    bool push(scope const(char)[] text)
    {
        size_t start;
        foreach (i; 0 .. text.length + 1)
        {
            if (i < text.length && text[i] != '/' && text[i] != '\\')
                continue;
            const part = text[start .. i];
            start = i + 1;
            if (part.length == 0 || part == ".")
                continue;
            if (part == "..")
            {
                if (path.length == 0)
                    return false;
                size_t cut = path.length;
                while (cut > 0 && path[cut - 1] != '/')
                    --cut;
                path = path[0 .. cut ? cut - 1 : 0];
                continue;
            }
            if (path.length)
                path ~= '/';
            path ~= part;
        }
        return true;
    }

    if (!push(packageDirectory) || !push(written))
    {
        why = OpaqueReason.outsideRepository;
        return false;
    }
    placed = path.idup;
    return true;
}

///
@("build_primitives.workspace.input_sets.repositoryPath")
@safe pure nothrow
unittest
{
    string placed;
    OpaqueReason why;
    assert(repositoryPath("libs/base", "src/", placed, why) && placed == "libs/base/src");
    assert(repositoryPath("libs/counters", "../harness/./src", placed, why) && placed == "libs/harness/src");
    assert(repositoryPath("libs/ui", "$PACKAGE_DIR/../dql/src", placed, why) && placed == "libs/dql/src");
    assert(repositoryPath("libs/ui", "../..", placed, why) && placed == "");
    assert(!repositoryPath("libs/ui", "../../../elsewhere", placed, why)
        && why == OpaqueReason.outsideRepository);
    assert(!repositoryPath("libs/ui", "/usr/include", placed, why) && why == OpaqueReason.outsideRepository);
    assert(!repositoryPath("libs/ui", "$GENERATED/src", placed, why) && why == OpaqueReason.variable);
    assert(!repositoryPath("libs/ui", "$PACKAGE_DIRS/src", placed, why) && why == OpaqueReason.variable);
    assert(!repositoryPath("libs/ui", `C:/d/src`, placed, why) && why == OpaqueReason.outsideRepository);
}

/// What a change to some paths can affect.
struct AffectedPackages
{
    /// By package index: an input set of its own holds a changed path.
    bool[] claimed;
    /// By package index: claimed, or depending, at any distance, on a
    /// package that is.
    bool[] affected;
    /// The changed paths no package's input set holds.
    string[] unclaimed;
}

/**
The packages a change to the repository-relative `changed` paths can affect:
those whose input set holds one, and every package that depends on one of
them. A path no set holds affects no package and is reported.

The result is sound and coarse: a dependent reads only some of a dependency's
modules, and which ones is known only after its compile ran. Reads no file.
*/
AffectedPackages affectedBy(ref PackageInputSets inputs, const ref PackageGraph graph,
    scope const(string)[] changed) @safe nothrow
in (inputs.length == graph.packages.length, "input sets of another graph")
{
    AffectedPackages result;
    result.claimed = new bool[graph.packages.length];
    foreach (path; changed)
    {
        bool any;
        inputs.eachClaimant(path, (uint i) { result.claimed[i] = any = true; });
        if (!any)
            result.unclaimed ~= path;
    }
    result.affected = result.claimed.dup;
    // Edges are sorted by dependent; dependencies come first in the order.
    foreach (at; graph.topologicalOrder)
        foreach (e; graph.edges)
            if (e.dependent == at && result.affected[e.dependency])
                result.affected[at] = true;
    return result;
}

/// Package `root` and every package it depends on, at any distance, in
/// index order.
uint[] dependencyClosure(const ref PackageGraph graph, uint root) @safe pure nothrow
{
    auto reached = new bool[graph.packages.length];
    reached[root] = true;
    foreach_reverse (at; graph.topologicalOrder)
        if (reached[at])
            foreach (e; graph.edges)
                if (e.dependent == at)
                    reached[e.dependency] = true;
    uint[] closure;
    foreach (i, r; reached)
        if (r)
            closure ~= cast(uint) i;
    return closure;
}

version (unittest)
{
    import std.algorithm.iteration : filter, map;
    import std.array : array;
    import std.range : iota;

    import sparkles.build_primitives.workspace.package_graph : buildPackageGraph, PackageId, recipe;

    private enum string[] linux = ["linux", "posix"];

    // `base` is silent about its paths; `counters` compiles the harness's
    // sources in its tests without depending on it; `ui` reads a catalog
    // outside every package; `odd` names what no set can hold.
    private SubPackageRecipe[] fixtureRecipes() @safe pure
        => [
            recipe("libs/base", `name "base"`),
            recipe("libs/harness", `name "harness"
importPaths "src"
dependency "sparkles:base" path="../.."`),
            recipe("libs/counters", `name "counters"
importPaths "src"
dependency "sparkles:base" path="../.."
configuration "library" {
}
configuration "unittest" {
    sourcePaths "src" "../harness/src"
    importPaths "src" "../harness/src"
}`),
            recipe("libs/ui", `name "ui"
importPaths "src"
stringImportPaths "views" "../../docs/specs/ui"
sourceFiles "src/shaping.c"
dependency "sparkles:base" path="../.."
configuration "library" {
    excludedSourceFiles "src/app.d" "src/backends/raylib_*.d"
}`),
            recipe("apps/demo", `name "demo"
dependency "sparkles:ui" path="../.."`),
            recipe("libs/odd", `name "odd"
sourcePaths "$GENERATED/src" "/usr/share/d" "../../../elsewhere"`),
        ];

    private string[] claimants(ref PackageInputSets sets, const ref PackageGraph graph, string path) @safe
    {
        string[] names;
        sets.eachClaimant(path, (uint i) { names ~= graph.packages[i].shortName; });
        return names;
    }

    private const(string)[] named(const ref PackageGraph graph, const bool[] flags) @safe
        => iota(flags.length).filter!(i => flags[i]).map!(i => graph.packages[i].shortName).array;
}

/// A package claims what its recipe reaches, not what its directory holds.
@("build_primitives.workspace.input_sets.packageInputSets.claimsWhatTheRecipeReaches")
@safe
unittest
{
    const recipes = fixtureRecipes();
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.test, linux).value;
    auto sets = packageInputSets(graph, recipes, RecipeRole.test, linux);

    // dub's default directories, with no probe: each candidate is covered.
    assert(claimants(sets, graph, "libs/base/src/a.d") == ["base"]);
    assert(claimants(sets, graph, "libs/base/source/deep/b.d") == ["base"]);
    assert(claimants(sets, graph, "libs/base/views/logo.txt") == ["base"]);
    assert(claimants(sets, graph, "libs/base/dub.sdl") == ["base"]);
    // In the package's directory, in no input set.
    assert(claimants(sets, graph, "libs/base/README.md") == []);
    assert(claimants(sets, graph, "libs/base/docs/guide.md") == []);
    assert(graph.packages[graph.owner("libs/base/README.md")].shortName == "base");
    // An import root is claimed whole; only modules are compiled, and none
    // with a hidden component, as dub skips them.
    const base = graph.indexOf(PackageId("sparkles:base"));
    assert(claimants(sets, graph, "libs/base/src/notes.txt") == ["base"]);
    assert(claimants(sets, graph, "libs/base/src/.cache/a.d") == ["base"]);
    assert(sets.compiles(base, "libs/base/src/a.d"));
    assert(!sets.compiles(base, "libs/base/src/notes.txt"));
    assert(!sets.compiles(base, "libs/base/src/.cache/a.d"));

    // In another package's directory, in this one's input set.
    assert(claimants(sets, graph, "libs/harness/src/h.d") == ["counters", "harness"]);
    assert(graph.packages[graph.owner("libs/harness/src/h.d")].shortName == "harness");
    // In no package's directory, in one's input set.
    assert(claimants(sets, graph, "docs/specs/ui/catalog.md") == ["ui"]);
    assert(graph.owner("docs/specs/ui/catalog.md") < 0);

    // An excluded module is not compiled, yet an import can still read it.
    const ui = graph.indexOf(PackageId("sparkles:ui"));
    assert(claimants(sets, graph, "libs/ui/src/app.d") == ["ui"]);
    assert(!sets.compiles(ui, "libs/ui/src/app.d"));
    assert(!sets.compiles(ui, "libs/ui/src/backends/raylib_gl.d"));
    assert(sets.compiles(ui, "libs/ui/src/backends/sdl.d"));
    assert(sets.compiles(ui, "libs/ui/src/shaping.c"));
    assert(!sets.compiles(ui, "libs/ui/views/x.glsl"));

    // What no set can hold is reported, not guessed at.
    assert(sets.opaque.map!(o => o.reason).array == [OpaqueReason.variable,
        OpaqueReason.outsideRepository, OpaqueReason.outsideRepository]);
    assert(sets.opaque[0].directive == "sourcePaths" && sets.opaque[0].value == "$GENERATED/src");
    assert(graph.packages[sets.opaque[0].package_].shortName == "odd");
}

/// The configuration decides the reach: only the tests compile the harness.
@("build_primitives.workspace.input_sets.packageInputSets.followsTheRole")
@safe
unittest
{
    const recipes = fixtureRecipes();
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
    auto sets = packageInputSets(graph, recipes, RecipeRole.build, linux);
    assert(claimants(sets, graph, "libs/harness/src/h.d") == ["harness"]);
}

/// Affected packages: the claimants and their dependents.
@("build_primitives.workspace.input_sets.affectedBy.claimantsAndDependents")
@safe
unittest
{
    const recipes = fixtureRecipes();
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.test, linux).value;
    auto sets = packageInputSets(graph, recipes, RecipeRole.test, linux);

    // The harness has no dependent in the graph: the reach is what selects
    // `counters`.
    const harness = affectedBy(sets, graph, ["libs/harness/src/h.d"]);
    assert(named(graph, harness.claimed) == ["counters", "harness"]);
    assert(named(graph, harness.affected) == ["counters", "harness"]);

    const catalog = affectedBy(sets, graph, ["docs/specs/ui/catalog.md"]);
    assert(named(graph, catalog.claimed) == ["ui"]);
    assert(named(graph, catalog.affected) == ["demo", "ui"]);

    const base = affectedBy(sets, graph, ["libs/base/src/a.d", "libs/base/README.md"]);
    assert(named(graph, base.affected) == ["base", "counters", "demo", "harness", "ui"]);
    assert(base.unclaimed == ["libs/base/README.md"]);

    const none = affectedBy(sets, graph, ["README.md", "libs/base/docs/guide.md"]);
    assert(named(graph, none.affected) == [] && none.unclaimed.length == 2);
}

/// The start roots of a package and what it depends on: where a watch of
/// `demo` begins, and where it never looks.
@("build_primitives.workspace.input_sets.startRoots.ofADependencyClosure")
@safe
unittest
{
    const recipes = fixtureRecipes();
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
    auto sets = packageInputSets(graph, recipes, RecipeRole.build, linux);

    const demo = cast(uint) graph.indexOf(PackageId("sparkles:demo"));
    const closure = dependencyClosure(graph, demo);
    assert(closure.map!(i => graph.packages[i].shortName).array == ["base", "demo", "ui"]);

    auto roots = sets.startRoots(closure);
    string[] listed;
    foreach (i; 0 .. roots.length)
        listed ~= roots[i].idup;
    assert(listed == ["apps/demo", "docs/specs/ui", "libs/base", "libs/ui"]);
}

/// The repository's own packages: the reaches a directory prefix cannot see.
@("build_primitives.workspace.input_sets.thisRepository")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import std.path : buildNormalizedPath;
    import sparkles.build_primitives.dub_manifest : hostPlatformTokens;
    import sparkles.build_primitives.workspace.package_graph : readWorkspaceRecipes;

    // This file is libs/build-primitives/src/sparkles/build_primitives/workspace/input_sets.d.
    const root = buildNormalizedPath(__FILE_FULL_PATH__, "../../../../../../..");
    const host = hostPlatformTokens();
    const read = readWorkspaceRecipes(root).value;

    const tested = buildPackageGraph(read.rootName, read.recipes, RecipeRole.test, host).value;
    auto testSets = packageInputSets(tested, read.recipes, RecipeRole.test, host);
    assert(testSets.opaque.length == 0, "every recipe path of the repository is analysable");

    // A module of `base` is claimed by `base` alone, and affects its dependents.
    const buffer = "libs/base/src/sparkles/base/buffer.d";
    assert(claimants(testSets, tested, buffer) == ["base"]);
    const affected = named(tested, affectedBy(testSets, tested, [buffer]).affected);
    assert(affected.canFind("text-lab") && affected.canFind("ci") && affected.canFind("ui"));
    assert(!affected.canFind("test-attributes"), "what `base` depends on is not affected");

    // The counters' tests compile the harness's sources (their recipe says
    // why), and the font oracle's tests compile one of font's fixtures.
    assert(claimants(testSets, tested, "libs/test-harness/src/sparkles/test_harness/package.d")
        .canFind("profiling-counters"));
    assert(claimants(testSets, tested, "libs/font/test/sparkles/font/fixtures.d").canFind("font-oracle"));

    // Documentation beside a recipe is in no input set; ownership by
    // directory would select `base` and everything that depends on it.
    const readme = affectedBy(testSets, tested, ["libs/base/README.md"]);
    assert(readme.unclaimed == ["libs/base/README.md"] && named(tested, readme.affected) == []);
    assert(tested.packages[tested.owner("libs/base/README.md")].shortName == "base");

    // `ci build --watch :text-lab`: the start roots of text-lab and what it
    // depends on are a few package directories, not the repository.
    const built = buildPackageGraph(read.rootName, read.recipes, RecipeRole.build, host).value;
    auto buildSets = packageInputSets(built, read.recipes, RecipeRole.build, host);
    const closure = dependencyClosure(built, cast(uint) built.indexOf(PackageId("sparkles:text-lab")));
    auto roots = buildSets.startRoots(closure);
    string[] listed;
    foreach (i; 0 .. roots.length)
        listed ~= roots[i].idup;
    assert(listed.canFind("apps/text-lab") && listed.canFind("libs/base"));
    assert(!listed.canFind("") && !listed.canFind("docs") && !listed.canFind("apps/hue"));
    assert(roots.length < built.packages.length, "fewer roots than packages");
}

/// A C source includes from its own directory, so the directory is read
/// whole; a package with no recipe is reported, never given an empty set.
@("build_primitives.workspace.input_sets.packageInputSets.cSourcesAndMissingRecipes")
@safe
unittest
{
    const recipes = [
        recipe("libs/shaping", `name "shaping"
sourcePaths "d"
importPaths "d"
sourceFiles "c/impl.c" "gen/*.d"
cSourcePaths "csrc"`),
        recipe("libs/other", `name "other"`),
    ];
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
    auto sets = packageInputSets(graph, recipes, RecipeRole.build, linux);
    const shaping = graph.indexOf(PackageId("sparkles:shaping"));

    assert(sets.compiles(shaping, "libs/shaping/c/impl.c"));
    assert(claimants(sets, graph, "libs/shaping/c/local.h") == ["shaping"]);
    assert(!sets.compiles(shaping, "libs/shaping/c/local.h"));
    assert(sets.compiles(shaping, "libs/shaping/csrc/deep/x.c"));
    assert(claimants(sets, graph, "libs/shaping/csrc/deep/x.h") == ["shaping"]);
    // A named source file may be a glob.
    assert(sets.compiles(shaping, "libs/shaping/gen/a.d"));
    assert(!sets.compiles(shaping, "libs/shaping/gen/deep/a.d"));
    assert(sets.opaque.length == 0);

    auto partial = packageInputSets(graph, recipes[0 .. 1], RecipeRole.build, linux);
    assert(partial.opaque.length == 1 && partial.opaque[0].reason == OpaqueReason.noRecipe);
    assert(graph.packages[partial.opaque[0].package_].shortName == "other");
}
