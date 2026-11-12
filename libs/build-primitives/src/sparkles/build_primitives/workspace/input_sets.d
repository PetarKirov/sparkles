/++
The packages' input sets: for every package of a
$(REF PackageGraph, sparkles,build_primitives,workspace,package_graph) and
every configuration it declares, the fileset of the files its own compile
can read, derived from its recipe
([design](../../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
BGW3–BGW6, BGW12).

A package's directory says where it lives. Its input set says what it reads:
its recipe, the modules under its source paths, every file under its import
and string-import roots, and the files it names one by one, wherever the
recipe points. An import root is taken whole, as the build graph's keys take
it (BGK6): what a compile may read there is not decided by a file's name. The
two differ in both directions. A `README.md` beside a recipe is in the
directory and in no input set; a source path of `../harness/src` is in the
input set and in another package's directory.

A set belongs to a package in one configuration, a $(LREF ConfiguredPackage),
because the configuration decides what the compile reads: `sparkles:ui` in
`gpu-effects` reads the shaders it generates, and in `unittest` the sources
of `sparkles:dql`. Which configuration a package is built in is the
resolver's answer for a request, so a change is judged against requests
($(LREF Request)): a request is affected when a pair of its closure claims a
changed path (decision D47). A path only `ui`'s test configuration claims
therefore affects `ui`'s test root, and no request that builds `ui` as a
dependency.

Every set lives in one arena, written relative to the repository root. A
set's start roots, the directories it lies beneath, index it: a query for the
sets claiming a path ($(LREF InputSets.eachClaimant)) evaluates only those
with a root above the path, and the union of a request's sets plans the
directories a watch of it starts from ($(LREF InputSets.startRoots)).

Construction is pure and total: it reads no file. A recipe path that names a
variable or leaves the repository, a flag that carries a path, and a command
are no part of any set and are reported ($(LREF InputSets.opaque)), never
guessed at. Where dub probes for a default directory (`source/`, `src/`,
`views/`), the set holds every candidate: a directory that does not exist
contributes no file, and one created later is already covered.
+/
module sparkles.build_primitives.workspace.input_sets;

import sparkles.build_primitives.dub_manifest : DubDependency, DubPlatformValues, platformsAllowHost;
import sparkles.build_primitives.fileset.listing : escapeGlob;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.plan : Plan, plan;
import sparkles.build_primitives.fileset.value : EntryFacts, Fileset, FilesetEvaluator, Filesets;
import sparkles.build_primitives.resolve.configure : Resolution;
import sparkles.build_primitives.workspace.package_graph : normalizeRepoPath, PackageGraph, PackageId,
    SubPackageRecipe;

/// A package in one configuration: what an input set belongs to. A package
/// that declares no configuration has one, named `""`.
struct ConfiguredPackage
{
    uint package_;        /// the package's index in the graph
    string configuration; /// as the recipe names it

    /// By package, then by configuration name.
    int opCmp(const ConfiguredPackage other) const @safe pure nothrow @nogc
    {
        if (package_ != other.package_)
            return package_ < other.package_ ? -1 : 1;
        return configuration < other.configuration ? -1 : configuration > other.configuration ? 1 : 0;
    }
}

/**
What a command resolves and builds: a root package in a configuration, or its
test root, on one platform. Its closure is every package and configuration
the resolution chose, the root's included, sorted, each once. The packages a
resolution reached that are not in the graph, registry packages and the
generated test root, are in `outside`: a change to a registry package arrives
through the lockfiles, which are workspace inputs.
*/
struct Request
{
    string name;                  /// what a report calls it: `text-lab`, `ui (test root)`
    ConfiguredPackage[] closure;  /// sorted, each pair once
    string[] outside;             /// reached, not in the graph; sorted
    /// The root package's index in the graph; -1 when it is not in it.
    ptrdiff_t root = -1;
    /**
    Why the request could not be resolved, or null. Such a request's
    closure is what is known without a resolution, the root's own pairs,
    and it is uncertain: what it reads is not all known.
    */
    string unresolved;
}

/**
The request a resolution of `name` stands for, over `graph`'s packages.
Pure: it reads the resolution's `configurations`, nothing else.
*/
Request requestOf(string name, const ref Resolution resolution, const ref PackageGraph graph) @safe pure nothrow
{
    import std.algorithm.sorting : sort;

    Request r;
    r.name = name;
    foreach (package_, chosen; resolution.configurations)
    {
        string configuration = chosen;
        // A test root builds dub's generated copy of a configuration, and
        // reads what the configuration it copies reads.
        if (package_ == resolution.rootPackage && resolution.testRoot.generated
                && configuration == resolution.testRoot.configuration)
            configuration = resolution.testRoot.base;
        const index = graph.indexOf(PackageId(package_));
        if (index < 0)
            r.outside ~= package_;
        else
            r.closure ~= ConfiguredPackage(cast(uint) index, configuration);
    }
    r.closure.sort();
    r.outside.sort();
    r.root = graph.indexOf(PackageId(resolution.rootPackage));
    return r;
}

/// Why a recipe entry is part of no input set.
enum OpaqueReason : ubyte
{
    variable,          /// a path names a variable other than a leading `$PACKAGE_DIR`
    outsideRepository, /// a path is absolute, or climbs above the repository root
    notAPattern,       /// a path is no fileset pattern
    noRecipe,          /// the package's recipe is not among those given
    pathFlag,          /// a compiler or linker flag carries a path
    command,           /// a command reads and writes what it likes
}

/**
A recipe entry that became part of no input set. One stated at a recipe's top
level has `configuration` `""` and concerns every configuration of the
package; one stated in a configuration block concerns that one.
*/
struct OpaqueDirective
{
    uint package_;        /// the package's index in the graph
    string configuration; /// the block it is stated in; `""` for the top level
    string directive;     /// `sourcePaths`
    string value;         /// as the recipe writes it
    OpaqueReason reason;  ///
}

/**
What every plan depends on besides the packages' own inputs (BGW12): a change
to any of it affects every request.
*/
struct WorkspaceInputs
{
    /// The repository-relative files planning read (BGP1): the recipes
    /// (`Workspace.reads`) and the lockfiles. One a package's set claims,
    /// such as a sub-package's recipe, is that package's input; the rest,
    /// the root recipe first, are workspace inputs. Derived, so none names a
    /// file that is not there.
    string[] read;
    /// Repository-relative fileset patterns no plan reads: the files that
    /// define the toolchain and the shell.
    string[] patterns;
    /// The first components of the importable modules (`sparkles`, `std`,
    /// `core`, …): beneath a top-level directory of such a name, a module
    /// would be found through the compiler's working directory, ahead of
    /// every import path (BGW7, D49).
    string[] moduleRoots;
    /// The closure of the command that plans the work: a change it claims
    /// changes the planner, and so every plan.
    ConfiguredPackage[] planner;
}

/**
The input sets of every package of one graph in every configuration it
declares, in one arena. Move-only, like the arena. Keys are in
$(LREF ConfiguredPackage) order.
*/
struct InputSets
{
    @disable this(this);

    private Filesets sets_;
    private ConfiguredPackage[] keys_;
    private Fileset[] inputs_;
    private Fileset[] sources_;
    private Fileset[] whole_;   // inputs and sources: what one key's evaluator judges
    private string[][] roots_;  // each key's start roots: the index a query consults first
    private bool[] opaque_;     // each key: an opaque entry concerns it
    private uint[][] dependsOn_; // each key: the in-graph packages its recipe depends on
    private FilesetEvaluator[] judges_; // made when a key is first a candidate
    private bool[] judging_;
    private Fileset workspace_;
    private string[] workspaceRoots_;
    private FilesetEvaluator workspaceJudge_;
    private bool workspaceJudging_;

    /// The recipe entries no set could hold, by package, then configuration,
    /// then recipe order; each once.
    OpaqueDirective[] opaque;

    /// The number of sets.
    size_t length() const @safe pure nothrow @nogc => keys_.length;

    /// The package and configuration set `index` belongs to.
    ConfiguredPackage key(size_t index) const @safe pure nothrow @nogc => keys_[index];

    /// The index of `pair`'s set, or -1. A package that declares no
    /// configuration answers for any name, as dub gives it a default one.
    ptrdiff_t indexOf(const ConfiguredPackage pair) const @safe pure nothrow @nogc
    {
        import std.range : assumeSorted;

        auto sorted = keys_.assumeSorted;
        auto at = sorted.lowerBound(pair).length;
        if (at < keys_.length && keys_[at] == pair)
            return at;
        // The only key of its package, and unnamed.
        const first = sorted.lowerBound(ConfiguredPackage(pair.package_, "")).length;
        if (first < keys_.length && keys_[first].package_ == pair.package_ && keys_[first].configuration == ""
            && (first + 1 == keys_.length || keys_[first + 1].package_ != pair.package_))
            return first;
        return -1;
    }

    /// The arena every set is built in; patterns are relative to the
    /// repository root.
    ref const(Filesets) sets() const return @safe pure nothrow @nogc => sets_;

    /// The files set `index`'s compile can read: its recipe, its source and
    /// import roots' files, its string imports and the files it names.
    Fileset inputs(size_t index) const @safe pure nothrow @nogc => inputs_[index];

    /// The modules set `index`'s compile is given: its source roots' modules
    /// and named source files, without the excluded ones. A subset of `inputs`.
    Fileset sources(size_t index) const @safe pure nothrow @nogc => sources_[index];

    /// Whether an opaque entry concerns set `index`: what it reads is not
    /// all stated, and a command that needs soundness treats it as claiming
    /// every path (BGW4).
    bool isOpaque(size_t index) const @safe pure nothrow @nogc => opaque_[index];

    /// The workspace inputs: the patterns, the working-directory lookup's
    /// paths and the planner's inputs.
    Fileset workspace() const @safe pure nothrow @nogc => workspace_;

    /**
    Calls `sink(index)` for each set that holds the repository-relative
    `path`, in key order. Reads no file: a path need not exist.

    The start roots are the index: only a set with a root above `path` is
    evaluated, so a query costs what the few sets reaching that directory
    cost, not what the repository does.
    */
    void eachClaimant(Sink)(scope const(char)[] path, scope Sink sink)
    {
        foreach (i, f; inputs_)
            if (reaches(roots_[i], path) && judge(i, path).selects(f))
                sink(i);
    }

    /// The directories the workspace inputs lie beneath, in path order.
    const(string)[] workspaceRoots() const return @safe pure nothrow @nogc => workspaceRoots_;

    /// Whether a workspace input holds `path`.
    bool inWorkspace(scope const(char)[] path) @safe nothrow
    {
        if (!reaches(workspaceRoots_, path))
            return false;
        if (!workspaceJudging_)
        {
            workspaceJudge_ = FilesetEvaluator(sets_, workspace_);
            workspaceJudging_ = true;
        }
        workspaceJudge_.judge(sets_, path, EntryFacts.init);
        return workspaceJudge_.selects(workspace_);
    }

    /// Whether set `index`'s compile is given the module at `path`.
    bool compiles(size_t index, scope const(char)[] path) @safe nothrow
        => reaches(roots_[index], path) && judge(index, path).selects(sources_[index]);

    /// The directories set `index` lies beneath, in path order: where its
    /// resolution starts.
    const(string)[] rootsOf(size_t index) const return @safe pure nothrow @nogc => roots_[index];

    // Whether one of `roots` is `path` or lies above it.
    private static bool reaches(scope const(string)[] roots, scope const(char)[] path)
        @safe pure nothrow @nogc
    {
        foreach (root; roots)
            if (root.length == 0 || (path.length >= root.length && path[0 .. root.length] == root
                    && (path.length == root.length || path[root.length] == '/')))
                return true;
        return false;
    }

    // Set `index`'s evaluator, having judged `path` against its inputs and
    // its sources in one walk.
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
    The directories a resolution, or a watch, of `request`'s sets starts
    from: no one beneath another, in path order. A pair the sets do not know
    contributes nothing; $(LREF affectedBy) reports it. The workspace inputs'
    are $(LREF workspaceRoots)'s. Adds the union to the arena.
    */
    Plan startRoots(const ref Request request) @safe nothrow @nogc
    {
        Fileset u = sets_.nothing;
        foreach (pair; request.closure)
        {
            const k = indexOf(pair);
            if (k >= 0)
                u = sets_.union_(u, inputs_[k]);
        }
        return plan(sets_, u);
    }

    /// The packages of the graph that set `index`'s recipe depends on, at
    /// its top level or in its configuration, in package order.
    const(uint)[] dependenciesOf(size_t index) const return @safe pure nothrow @nogc => dependsOn_[index];

    /**
    Every set's reaches (§2): its start roots that lie outside its package's
    territory, by set, then root. `graph` is the one the sets were built
    from.
    */
    Reach[] reaches(const ref PackageGraph graph) const @safe pure nothrow
    {
        Reach[] result;
        foreach (i, roots; roots_)
        {
            const self = keys_[i].package_;
            foreach (root; roots)
            {
                const owner = graph.owner(root);
                if (owner == self)
                    continue;
                uint[] into;
                foreach (q, ref p; graph.packages)
                    if (q != self && (q == owner || beneath(p.path, root)))
                        into ~= cast(uint) q;
                result ~= Reach(i, root, into);
            }
        }
        return result;
    }

    /**
    The hidden edges (BGR8) as the sets show them: each package a set reaches
    into that its recipe does not depend on. Comparison alone: the paths
    were resolved when the sets were built (BGW7).
    */
    HiddenReach[] hiddenReaches(const ref PackageGraph graph) const @safe pure nothrow
    {
        import std.algorithm.searching : canFind;

        HiddenReach[] result;
        foreach (ref reach; reaches(graph))
            foreach (q; reach.into)
                if (!dependsOn_[reach.set].canFind(q))
                    result ~= HiddenReach(reach.set, reach.root, q);
        return result;
    }

    // Whether `path` is `dir` or lies beneath it; everything lies beneath `""`.
    private static bool beneath(scope const(char)[] path, scope const(char)[] dir) @safe pure nothrow @nogc
        => dir.length == 0 || (path.length >= dir.length && path[0 .. dir.length] == dir
            && (path.length == dir.length || path[dir.length] == '/'));
}

/// A start root of a set that lies outside its package's territory: the set
/// reads files its package does not own (§2).
struct Reach
{
    size_t set;  /// the set's index
    string root; /// repository-relative
    /// The packages whose files may lie beneath it: its owner and every
    /// package whose directory it holds, the set's own excluded; in package
    /// order. Empty for a root in no package, such as a documentation tree.
    uint[] into;
}

/// A reach into a package its set's recipe does not depend on.
struct HiddenReach
{
    size_t set;    /// the set's index
    string root;   /// the reach's root
    uint package_; /// the package reached
}

/**
Builds the input set of every package of `graph`, in every configuration its
recipe in `recipes` declares for a host described by `hostTokens`, and the
workspace inputs. Pure and total; see the module's notes on what a set holds.
*/
InputSets inputSets(const ref PackageGraph graph, scope const(SubPackageRecipe)[] recipes,
    scope const(string)[] hostTokens, in WorkspaceInputs workspace) @safe nothrow
{
    InputSets result;
    result.sets_ = Filesets(CasePolicy.sensitive);

    foreach (i, ref p; graph.packages)
    {
        const(SubPackageRecipe)* found;
        foreach (ref r; recipes)
            if (normalizeRepoPath(r.path) == p.path)
            {
                found = &r;
                break;
            }
        auto b = Builder(&result.sets_, &result.opaque, cast(uint) i, p.path);
        if (found is null)
        {
            // Nothing is known of what it reads: say so, not an empty set.
            b.report("", "recipe", p.path, OpaqueReason.noRecipe);
            b.begin();
            result.add(ConfiguredPackage(cast(uint) i, ""), b, true, null);
            continue;
        }
        const manifest = &found.manifest;
        bool any;
        foreach (ref c; manifest.configurations)
        {
            if (!platformsAllowHost(c.platforms, hostTokens))
                continue;
            any = true;
            b.begin();
            b.configuration = "";
            b.top(*manifest);
            b.block(*manifest, hostTokens);
            b.configuration = c.name;
            b.block(c, hostTokens);
            result.add(ConfiguredPackage(cast(uint) i, c.name), b, b.opaque,
                inGraph(graph, manifest.dependencies, c.dependencies));
        }
        if (!any)
        {
            b.begin();
            b.configuration = "";
            b.top(*manifest);
            b.block(*manifest, hostTokens);
            result.add(ConfiguredPackage(cast(uint) i, ""), b, b.opaque, inGraph(graph, manifest.dependencies, null));
        }
    }
    result.judges_ = new FilesetEvaluator[result.keys_.length];
    result.judging_ = new bool[result.keys_.length];

    // The workspace inputs: what planning read and no set claims, the stated
    // patterns, the working-directory lookup's paths, and the planner's own
    // inputs.
    auto sets = &result.sets_;
    Fileset w = sets.nothing;
    foreach (path; workspace.read)
    {
        bool claimed;
        result.eachClaimant(path, (size_t _) { claimed = true; });
        if (!claimed)
            w = sets.union_(w, sets.glob("/" ~ escapeGlob(path)).value);
    }
    foreach (pattern; workspace.patterns)
    {
        auto g = sets.glob("/" ~ pattern);
        if (g.hasError)
            result.opaque ~= OpaqueDirective(uint.max, "", "workspace", pattern, OpaqueReason.notAPattern);
        else
            w = sets.union_(w, g.value);
    }
    foreach (name; ["*.d", "*.di", "*.c", "*.i", "*.h"])
        w = sets.union_(w, sets.glob("/" ~ name).value);
    foreach (name; workspace.moduleRoots)
        w = sets.union_(w, sets.glob("/" ~ escapeGlob(name) ~ "/**").value);
    foreach (pair; workspace.planner)
    {
        const k = result.indexOf(pair);
        if (k >= 0)
            w = sets.union_(w, result.inputs_[k]);
    }
    result.workspace_ = w;
    auto roots = plan(result.sets_, w);
    foreach (k; 0 .. roots.length)
        result.workspaceRoots_ ~= roots[k].idup;
    return result;
}

// Records the set `b` built for `pair`. Keys arrive in package order, and
// within a package in recipe order, so the package's run is sorted here.
private void add(ref InputSets s, ConfiguredPackage pair, scope ref Builder b, bool opaque, uint[] dependencies)
    @safe nothrow
{
    s.keys_ ~= pair;
    s.inputs_ ~= b.inputs();
    s.sources_ ~= b.sources();
    s.whole_ ~= s.sets_.union_(s.inputs_[$ - 1], s.sources_[$ - 1]);
    auto roots = plan(s.sets_, s.inputs_[$ - 1]);
    string[] own;
    foreach (k; 0 .. roots.length)
        own ~= roots[k].idup;
    s.roots_ ~= own;
    s.opaque_ ~= opaque;
    s.dependsOn_ ~= dependencies;

    // Insertion into the package's sorted run.
    for (size_t at = s.keys_.length - 1; at > 0 && s.keys_[at] < s.keys_[at - 1]; --at)
    {
        swapAt(s.keys_, at);
        swapAt(s.inputs_, at);
        swapAt(s.sources_, at);
        swapAt(s.whole_, at);
        swapAt(s.roots_, at);
        swapAt(s.opaque_, at);
        swapAt(s.dependsOn_, at);
    }
}

// The packages of `graph` that a recipe's top level and one configuration
// depend on, in package order, each once.
private uint[] inGraph(const ref PackageGraph graph, scope const(DubDependency)[] top,
    scope const(DubDependency)[] configuration) @safe pure nothrow
{
    import std.algorithm.sorting : sort;
    import std.algorithm.iteration : uniq;
    import std.array : array;

    uint[] result;
    foreach (ref d; top ~ configuration)
    {
        const at = graph.indexOf(PackageId(d.name));
        if (at >= 0)
            result ~= cast(uint) at;
    }
    result.sort();
    return result.uniq.array;
}

private void swapAt(T)(T[] a, size_t at)
{
    auto t = a[at];
    a[at] = a[at - 1];
    a[at - 1] = t;
}

// One set under construction.
private struct Builder
{
    Filesets* sets;
    OpaqueDirective[]* opaques;
    uint index;
    string directory;     // repository-relative
    string configuration; // the block being read; `""` for the top level

    Fileset compiled, excluded, read;
    bool opaque;          // an opaque entry concerns this set

    void begin() scope @safe nothrow
    {
        compiled = sets.nothing;
        excluded = sets.nothing;
        opaque = false;
        // The recipe itself.
        read = literal("dub.sdl", "dub.sdl");
    }

    Fileset inputs() scope @safe nothrow @nogc => sets.union_(read, compiled);

    Fileset sources() scope @safe nothrow @nogc => sets.difference(compiled, excluded);

    // Records an opaque entry once, and marks this set.
    void report(scope const(char)[] block, scope const(char)[] directive, scope const(char)[] value,
        OpaqueReason why) scope @safe nothrow
    {
        opaque = true;
        foreach (ref o; *opaques)
            if (o.package_ == index && o.configuration == block && o.directive == directive && o.value == value)
                return;
        *opaques ~= OpaqueDirective(index, block.idup, directive.idup, value.idup, why);
    }

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

        // What reaches files no row of the table covers (BGW3).
        each("dflags", settings.dflags, (v) {
            if (carriesPath(v, compilerPathFlags))
                report(configuration, "dflags", v, OpaqueReason.pathFlag);
        });
        each("lflags", settings.lflags, (v) {
            if (carriesPath(v, linkerPathFlags))
                report(configuration, "lflags", v, OpaqueReason.pathFlag);
        });
        // `dub run` and `dub test` run the target between the run commands.
        static foreach (directive; ["preGenerateCommands", "postGenerateCommands", "preBuildCommands",
                "postBuildCommands", "preRunCommands", "postRunCommands"])
            each(directive, __traits(getMember, settings, directive),
                v => report(configuration, directive, v, OpaqueReason.command));
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
            report(configuration, directive, written, OpaqueReason.notAPattern);
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
        report(configuration, directive, written, why);
        return false;
    }
}

// The compiler flags that name a file or a directory to read: import,
// string-import and C include directories, a response file and a
// configuration file.
private immutable string[] compilerPathFlags = ["-I", "-J", "-P-I", "-Xcc=-I", "-conf=", "@"];

// The linker flags that name a directory or a file to read.
private immutable string[] linkerPathFlags = ["-L", "@"];

// Whether `flag` starts with one of `prefixes`.
private bool carriesPath(scope const(char)[] flag, scope const(string)[] prefixes) @safe pure nothrow @nogc
{
    foreach (p; prefixes)
        if (flag.length >= p.length && flag[0 .. p.length] == p)
            return true;
    return false;
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
struct AffectedRequests
{
    /// By set index: the set holds a changed path.
    bool[] claimed;
    /// By request: a pair of its closure claims a changed path, or a
    /// workspace input holds one.
    bool[] affected;
    /**
    By request: it is unresolved, or its closure holds a pair the sets do
    not know, or an opaque one, so what it reads is not all stated. A
    command that needs soundness treats such a request as affected by every
    change (BGW4).
    */
    bool[] uncertain;
    /// The changed paths a workspace input holds: each affects every request.
    string[] everywhere;
    /// The changed paths no set and no workspace input holds.
    string[] unclaimed;
}

/**
The requests a change to the repository-relative `changed` paths affects:
those whose closure holds a pair claiming one, and every request when a
workspace input holds one (BGW12). A path nothing holds affects no request
and is reported.

The result is sound and coarse: a compile reads only some of a dependency's
modules, and which ones is known only after it ran. Reads no file.
*/
AffectedRequests affectedBy(ref InputSets inputs, scope const(Request)[] requests,
    scope const(string)[] changed) @safe nothrow
{
    AffectedRequests result;
    result.claimed = new bool[inputs.length];
    bool everything;
    foreach (path; changed)
    {
        bool any;
        inputs.eachClaimant(path, (size_t i) { result.claimed[i] = any = true; });
        if (inputs.inWorkspace(path))
        {
            result.everywhere ~= path;
            everything = any = true;
        }
        if (!any)
            result.unclaimed ~= path;
    }
    result.affected = new bool[requests.length];
    result.uncertain = new bool[requests.length];
    foreach (r, ref request; requests)
    {
        result.affected[r] = everything;
        result.uncertain[r] = request.unresolved.length > 0;
        foreach (pair; request.closure)
        {
            const k = inputs.indexOf(pair);
            if (k < 0 || inputs.isOpaque(k))
                result.uncertain[r] = true;
            else if (result.claimed[k])
                result.affected[r] = true;
        }
    }
    return result;
}

version (unittest)
{
    import std.algorithm.iteration : filter, map;
    import std.array : array;
    import std.algorithm.searching : canFind;
    import std.conv : text;
    import std.range : iota;

    import sparkles.build_primitives.workspace.package_graph : buildPackageGraph, recipe, RecipeRole;

    private enum string[] linux = ["linux", "posix"];

    // `base` is silent about its paths; `counters` compiles the harness's
    // sources in its tests without depending on it; `ui` reads a catalog
    // outside every package, generates shaders in one configuration and
    // compiles `dql` in its tests; `odd` names what no set can hold.
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
            recipe("libs/dql", `name "dql"`),
            recipe("libs/ui", `name "ui"
importPaths "src"
stringImportPaths "views" "../../docs/specs/ui"
sourceFiles "src/shaping.c"
dependency "sparkles:base" path="../.."
configuration "library" {
    excludedSourceFiles "src/app.d" "src/backends/raylib_*.d"
}
configuration "gpu-effects" {
    stringImportPaths "generated/shaders"
}
configuration "unittest" {
    sourcePaths "src" "../dql/src"
}
configuration "windows-only" {
    platforms "windows"
}`),
            recipe("apps/demo", `name "demo"
dependency "sparkles:ui" path="../.."`),
            recipe("apps/viewer", `name "viewer"
dependency "sparkles:ui" path="../.."
subConfiguration "sparkles:ui" "gpu-effects"`),
            recipe("libs/odd", `name "odd"
sourcePaths "$GENERATED/src" "/usr/share/d" "../../../elsewhere"`),
        ];

    // The graph, the sets, and requests made by hand as a resolution would
    // make them.
    private struct Fixture
    {
        PackageGraph graph;
        InputSets sets;

        ConfiguredPackage pair(string name, string configuration = "") const @safe
            => ConfiguredPackage(cast(uint) graph.indexOf(PackageId("sparkles:" ~ name)), configuration);

        Request request(string name, ConfiguredPackage[] closure) const @safe
        {
            import std.algorithm.sorting : sort;

            closure.sort();
            return Request(name, closure);
        }

        string[] claimants(string path) @safe
        {
            string[] names;
            sets.eachClaimant(path, (size_t i) {
                const k = sets.key(i);
                names ~= text(graph.packages[k.package_].shortName, k.configuration.length ? ":" : "",
                    k.configuration);
            });
            return names;
        }
    }

    private Fixture fixture(WorkspaceInputs workspace = WorkspaceInputs.init) @safe
    {
        const recipes = fixtureRecipes();
        auto graph = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
        return Fixture(graph, inputSets(graph, recipes, linux, workspace));
    }

    private const(string)[] named(scope const(Request)[] requests, const bool[] flags) @safe
        => iota(flags.length).filter!(i => flags[i]).map!(i => requests[i].name).array;
}

/// A set claims what its recipe reaches in its configuration, not what the
/// package's directory holds.
@("build_primitives.workspace.input_sets.inputSets.claimsWhatTheRecipeReaches")
@safe
unittest
{
    auto f = fixture();

    // dub's default directories, with no probe: each candidate is covered.
    assert(f.claimants("libs/base/src/a.d") == ["base"]);
    assert(f.claimants("libs/base/source/deep/b.d") == ["base"]);
    assert(f.claimants("libs/base/views/logo.txt") == ["base"]);
    assert(f.claimants("libs/base/dub.sdl") == ["base"]);
    // In the package's directory, in no input set.
    assert(f.claimants("libs/base/README.md") == []);
    assert(f.claimants("libs/base/docs/guide.md") == []);
    assert(f.graph.packages[f.graph.owner("libs/base/README.md")].shortName == "base");
    // An import root is claimed whole; only modules are compiled, and none
    // with a hidden component, as dub skips them.
    const base = f.sets.indexOf(f.pair("base"));
    assert(f.claimants("libs/base/src/notes.txt") == ["base"]);
    assert(f.claimants("libs/base/src/.cache/a.d") == ["base"]);
    assert(f.sets.compiles(base, "libs/base/src/a.d"));
    assert(!f.sets.compiles(base, "libs/base/src/notes.txt"));
    assert(!f.sets.compiles(base, "libs/base/src/.cache/a.d"));

    // In another package's directory, in one configuration's input set.
    assert(f.claimants("libs/harness/src/h.d") == ["counters:unittest", "harness"]);
    assert(f.graph.packages[f.graph.owner("libs/harness/src/h.d")].shortName == "harness");
    // In no package's directory, in every configuration of `ui`.
    assert(f.claimants("docs/specs/ui/catalog.md") == ["ui:gpu-effects", "ui:library", "ui:unittest"]);
    assert(f.graph.owner("docs/specs/ui/catalog.md") < 0);
    // Only the configuration that states it reads the generated shaders.
    assert(f.claimants("libs/ui/generated/shaders/blur.glsl") == ["ui:gpu-effects"]);
    // A configuration the host does not allow has no set.
    assert(f.sets.indexOf(f.pair("ui", "windows-only")) < 0);

    // An excluded module is not compiled, yet an import can still read it.
    const library = f.sets.indexOf(f.pair("ui", "library"));
    const effects = f.sets.indexOf(f.pair("ui", "gpu-effects"));
    assert(f.claimants("libs/ui/src/app.d") == ["ui:gpu-effects", "ui:library", "ui:unittest"]);
    assert(!f.sets.compiles(library, "libs/ui/src/app.d"));
    assert(f.sets.compiles(effects, "libs/ui/src/app.d"));
    assert(!f.sets.compiles(library, "libs/ui/src/backends/raylib_gl.d"));
    assert(f.sets.compiles(library, "libs/ui/src/backends/sdl.d"));
    assert(f.sets.compiles(library, "libs/ui/src/shaping.c"));
    assert(!f.sets.compiles(library, "libs/ui/views/x.glsl"));

    // What no set can hold is reported, not guessed at.
    assert(f.sets.opaque.map!(o => o.reason).array == [OpaqueReason.variable,
        OpaqueReason.outsideRepository, OpaqueReason.outsideRepository]);
    assert(f.sets.opaque[0].directive == "sourcePaths" && f.sets.opaque[0].value == "$GENERATED/src");
    assert(f.graph.packages[f.sets.opaque[0].package_].shortName == "odd");
    assert(f.sets.isOpaque(f.sets.indexOf(f.pair("odd"))) && !f.sets.isOpaque(base));
}

/// Requests, not packages, are affected: a path only `ui`'s tests read
/// affects `ui`'s test root and no request that builds `ui` as a
/// dependency, and the generated shaders affect only the request that
/// builds `ui` with them.
@("build_primitives.workspace.input_sets.affectedBy.followsTheRequests")
@safe
unittest
{
    auto f = fixture();
    const requests = [
        f.request("demo", [f.pair("demo"), f.pair("ui", "library"), f.pair("base")]),
        f.request("viewer", [f.pair("viewer"), f.pair("ui", "gpu-effects"), f.pair("base")]),
        f.request("ui (test root)", [f.pair("ui", "unittest"), f.pair("base")]),
        f.request("counters (test root)", [f.pair("counters", "unittest"), f.pair("base")]),
    ];
    alias affected = (string[] paths) => named(requests, affectedBy(f.sets, requests, paths).affected);

    assert(affected(["libs/dql/src/query.d"]) == ["ui (test root)"]);
    assert(affected(["libs/ui/generated/shaders/blur.glsl"]) == ["viewer"]);
    assert(affected(["libs/ui/src/widget.d"]) == ["demo", "viewer", "ui (test root)"]);
    assert(affected(["libs/base/src/a.d"]) == ["demo", "viewer", "ui (test root)", "counters (test root)"]);
    // The harness has no dependent here: the reach is what selects the counters.
    assert(affected(["libs/harness/src/h.d"]) == ["counters (test root)"]);

    const none = affectedBy(f.sets, requests, ["README.md", "libs/base/docs/guide.md"]);
    assert(named(requests, none.affected) == [] && none.unclaimed == ["README.md", "libs/base/docs/guide.md"]);
    assert(none.everywhere.length == 0);

    // A pair the sets do not know leaves its request uncertain.
    const odd = [f.request("windows", [f.pair("ui", "windows-only")]), f.request("odd", [f.pair("odd")])];
    const unknown = affectedBy(f.sets, odd, ["libs/base/src/a.d"]);
    assert(unknown.uncertain == [true, true] && unknown.affected == [false, false]);
}

/// The workspace inputs affect every request: the stated patterns, the
/// planner's inputs, and what the compiler's working-directory lookup could
/// find (D49), which a `README.md` at the root is not.
@("build_primitives.workspace.input_sets.affectedBy.workspaceInputs")
@safe
unittest
{
    WorkspaceInputs workspace;
    workspace.patterns = ["dub.sdl", "nix/*-lock.json"];
    workspace.moduleRoots = ["sparkles", "std", "core"];
    auto f = fixture(workspace);
    const requests = [f.request("demo", [f.pair("demo"), f.pair("ui", "library"), f.pair("base")]),
        f.request("ui (test root)", [f.pair("ui", "unittest"), f.pair("base")])];

    foreach (path; ["dub.sdl", "nix/dub-lock.json", "sparkles/base/buffer.d", "std/stdio.d", "object.d",
            "shim.c"])
    {
        const a = affectedBy(f.sets, requests, [path]);
        assert(a.affected == [true, true] && a.everywhere == [path], path);
    }
    foreach (path; ["README.md", "flake.nix", "nix/shells/default.nix", "docs/sparkles/x.d"])
    {
        const a = affectedBy(f.sets, requests, [path]);
        assert(a.affected == [false, false] && a.unclaimed == [path], path);
    }

    // The planner's own inputs: a change to what plans the work changes
    // every plan.
    WorkspaceInputs planned;
    planned.planner = [ConfiguredPackage(cast(uint) f.graph.indexOf(PackageId("sparkles:harness")), "")];
    auto g = fixture(planned);
    const a = affectedBy(g.sets, requests, ["libs/harness/src/h.d"]);
    assert(a.affected == [true, true] && a.everywhere == ["libs/harness/src/h.d"]);
}

/// The start roots of a request: where a watch of `viewer` begins, and where
/// it never looks.
@("build_primitives.workspace.input_sets.startRoots.ofARequest")
@safe
unittest
{
    WorkspaceInputs workspace;
    workspace.patterns = ["dub.sdl"];
    auto f = fixture(workspace);
    const viewer = f.request("viewer", [f.pair("viewer"), f.pair("ui", "gpu-effects"), f.pair("base")]);
    auto roots = f.sets.startRoots(viewer);
    string[] listed;
    foreach (i; 0 .. roots.length)
        listed ~= roots[i].idup;
    assert(listed == ["apps/viewer", "docs/specs/ui", "libs/base", "libs/ui"], listed.text);
    // The workspace inputs are patterns of the root's own entries: a watch
    // lists the root, and walks nothing beneath it on their account.
    assert(f.sets.workspaceRoots == [""]);
}

/// A resolution's configurations, as a request over the graph.
@("build_primitives.workspace.input_sets.requestOf.aResolution")
@safe
unittest
{
    import sparkles.build_primitives.resolve.configure : resolve, ResolveRequest;
    import sparkles.build_primitives.resolve.driver : MemoryDriver;
    import sparkles.build_primitives.resolve.platform : BuildPlatform;

    string[string] texts = [
        "/r/dub.sdl": "name \"r\"\nsubPackage \"app\"\nsubPackage \"lib\"\n",
        "/r/app/dub.sdl": "name \"app\"\ntargetType \"executable\"\ndependency \"r:lib\" path=\"..\"\n"
            ~ "subConfiguration \"r:lib\" \"fancy\"\n",
        "/r/app/source/app.d": "void main() {}",
        "/r/lib/dub.sdl": "name \"lib\"\nconfiguration \"plain\" {\n}\nconfiguration \"fancy\" {\n"
            ~ "    stringImportPaths \"fancy\"\n}\n",
        "/r/lib/source/lib.d": "",
    ];
    auto driver = new MemoryDriver(texts);
    auto platform = BuildPlatform(["linux", "posix"], ["x86_64"], "ldc", "ldc2", 2111, "1.41.0");
    const resolution = resolve(ResolveRequest(directory: "/r", subPackage: "app", platform: platform), driver);
    assert(!resolution.hasError, resolution.hasError ? resolution.error.message : "");

    const recipes = [recipe("app", texts["/r/app/dub.sdl"]), recipe("lib", texts["/r/lib/dub.sdl"])];
    const graph = buildPackageGraph("r", recipes, RecipeRole.build, linux).value;
    const request = requestOf("app", resolution.value, graph);
    const app = cast(uint) graph.indexOf(PackageId("r:app"));
    const lib = cast(uint) graph.indexOf(PackageId("r:lib"));
    assert(request.closure.length == 2 && request.closure.canFind(ConfiguredPackage(lib, "fancy")), request.text);
    assert(request.closure[0].package_ == app || request.closure[1].package_ == app);
    assert(request.outside.length == 0);

    auto sets = inputSets(graph, recipes, linux, WorkspaceInputs.init);
    const affected = affectedBy(sets, [request], ["lib/fancy/banner.txt"]);
    assert(affected.affected == [true] && affected.uncertain == [false]);
    assert(affectedBy(sets, [request], ["lib/plain.txt"]).affected == [false]);
}

/// The repository's own packages, resolved as `ci` would ask: the reaches a
/// directory prefix cannot see, and the configurations dub picks.
@("build_primitives.workspace.input_sets.thisRepository")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.path : buildNormalizedPath, buildPath;
    import std.process : environment;

    import sparkles.build_primitives.dub_manifest : hostPlatformTokens;
    import sparkles.build_primitives.resolve.configure : resolve, ResolveRequest;
    import sparkles.build_primitives.resolve.driver : SystemDriver;
    import sparkles.build_primitives.resolve.platform : BuildPlatform;
    import sparkles.build_primitives.resolve.registry : nixRegistrySources, readDubLocks;
    import sparkles.build_primitives.workspace.discovery : readWorkspaceAt;
    import sparkles.test_runner.skip : skipTest;

    // The registry packages' sources, as the dev shell exports them.
    const sources = environment.get("SPARKLES_DUB_SOURCES");
    if (sources is null)
        skipTest("SPARKLES_DUB_SOURCES is not set");

    // This file is libs/build-primitives/src/sparkles/build_primitives/workspace/input_sets.d.
    const root = buildNormalizedPath(__FILE_FULL_PATH__, "../../../../../../..");
    const read = readWorkspaceAt(root).value;
    const host = ["linux", "posix"];
    auto platform = BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2111, "1.41.0");
    auto driver = new SystemDriver;
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")],
        driver);
    assert(!locked.hasError, locked.hasError ? locked.error : "");
    const registry = nixRegistrySources(locked.value, sources, driver);
    assert(!registry.hasError, registry.hasError ? registry.error : "");

    const graph = buildPackageGraph(read.rootName, read.recipes, RecipeRole.build, host).value;
    WorkspaceInputs workspace;
    workspace.patterns = ["dub.sdl", "dub.selections.json", "nix/dub-lock.json"];
    workspace.moduleRoots = ["sparkles", "std", "core", "etc", "ldc"];
    auto sets = inputSets(graph, read.recipes, host, workspace);

    string[] resolverHidden; // `package:configuration reached`, from every resolution
    Request ask(string name, string subPackage, bool testRoot)
    {
        auto request = ResolveRequest(directory: root, subPackage: subPackage, platform: platform,
            testRoot: testRoot);
        foreach (n, s; registry.value)
            request.registry[n] = s;
        const r = resolve(request, driver);
        assert(!r.hasError, text(name, ": ", r.hasError ? r.error.message : ""));
        foreach (ref e; r.value.hiddenEdges)
        {
            const edge = text(e.package_["sparkles:".length .. $], ":", e.configuration, " ",
                e.reached["sparkles:".length .. $]);
            if (!resolverHidden.canFind(edge))
                resolverHidden ~= edge;
        }
        return requestOf(name, r.value, graph);
    }

    const requests = [
        ask("text-lab", "text-lab", false),
        ask("ui (test root)", "ui", true),
        ask("core-cli", "core-cli", false),
    ];
    // For its hidden edge alone.
    cast(void) ask("profiling-counters (test root)", "profiling-counters", true);
    // Every pair a resolution chose has a set.
    foreach (ref r; requests)
        foreach (pair; r.closure)
            assert(sets.indexOf(pair) >= 0, text(r.name, ": no set for ",
                graph.packages[pair.package_].shortName, " in ", pair.configuration));
    // dub builds text-lab's `ui` with the generated shaders.
    const ui = cast(uint) graph.indexOf(PackageId("sparkles:ui"));
    assert(requests[0].closure.canFind(ConfiguredPackage(ui, "gpu-effects")), requests[0].text);

    alias affected = (string path) => named(requests, affectedBy(sets, requests, [path]).affected);
    // A module of `base` affects all three.
    assert(affected("libs/base/src/sparkles/base/buffer.d") == ["text-lab", "ui (test root)", "core-cli"]);
    // `ui`'s tests compile `dql`'s sources; nothing else that builds `ui` does.
    assert(affected("libs/dql/src/sparkles/dql/package.d") == ["ui (test root)"]);
    // Documentation beside a recipe is in no input set.
    const readme = affectedBy(sets, requests, ["libs/base/README.md"]);
    assert(named(requests, readme.affected) == [] && readme.unclaimed == ["libs/base/README.md"]);
    // A new top-level `sparkles/` would shadow modules for every compile.
    assert(affected("sparkles/base/buffer.d") == ["text-lab", "ui (test root)", "core-cli"]);

    // The counters' tests compile the harness's sources (their recipe says
    // why), and the font oracle's tests compile one of font's fixtures.
    string[] claimants(string path)
    {
        string[] names;
        sets.eachClaimant(path, (size_t i) {
            names ~= text(graph.packages[sets.key(i).package_].shortName, ":", sets.key(i).configuration);
        });
        return names;
    }

    assert(claimants("libs/test-harness/src/sparkles/test_harness/package.d").canFind("profiling-counters:unittest"));
    assert(claimants("libs/font/test/sparkles/font/fixtures.d").canFind("font-oracle:unittest"));

    // The shader generators are commands: what they read is not stated, so a
    // request that reaches one is uncertain until generators are typed.
    // The only other entries no set can hold: the profiler's Tracy
    // configurations read through a variable, outside the repository.
    assert(sets.opaque.map!(o => text(graph.packages[o.package_].shortName, " ", o.configuration, " ",
        o.directive, " ", o.reason)).array == [
        "profiling tracy cImportPaths variable", "profiling tracy lflags pathFlag",
        "profiling unittest-tracy cImportPaths variable", "profiling unittest-tracy lflags pathFlag",
        "ui gpu-effects preGenerateCommands command", "ui-vulkan library preGenerateCommands command",
        "ui-vulkan unittest preGenerateCommands command", "vulkan-wsi gpu-shaders preGenerateCommands command",
    ], sets.opaque.text);
    assert(affectedBy(sets, requests, ["README.md"]).uncertain[0], "text-lab reaches a generator");
    assert(!affectedBy(sets, requests, ["README.md"]).uncertain[2], "core-cli reaches none");

    // `ci build --watch :text-lab`: its start roots are a few package
    // directories, not the repository.
    auto roots = sets.startRoots(requests[0]);
    string[] listed;
    foreach (i; 0 .. roots.length)
        listed ~= roots[i].idup;
    assert(listed.canFind("apps/text-lab") && listed.canFind("libs/base"), listed.text);
    assert(!listed.canFind("") && !listed.canFind("docs") && !listed.canFind("apps/hue"), listed.text);
    assert(roots.length < graph.packages.length, "fewer roots than packages");

    // This repository's reaches into other packages. Two are hidden edges
    // that the recipes say are test-only and the build graph's E1 removes,
    // and the lint over the sets finds what the resolver's (oracle 13) finds.
    string[] intoPackages;
    foreach (ref r; sets.reaches(graph))
        if (r.into.length)
        {
            const k = sets.key(r.set);
            intoPackages ~= text(graph.packages[k.package_].shortName, ":", k.configuration, " ", r.root);
        }
    assert(intoPackages == [
        "font-oracle:unittest libs/font/test",
        "profiling-counters:unittest libs/test-harness/src",
        "ui:unittest libs/dql/src",
    ], intoPackages.text);
    string[] hidden;
    foreach (ref h; sets.hiddenReaches(graph))
        hidden ~= text(graph.packages[sets.key(h.set).package_].shortName, ":", sets.key(h.set).configuration, " ",
            graph.packages[h.package_].shortName);
    assert(hidden == ["profiling-counters:unittest test-harness", "ui:unittest dql"], hidden.text);
    import std.algorithm.sorting : sort;

    resolverHidden.sort();
    assert(resolverHidden == hidden, resolverHidden.text);
}

/// A reach is a start root outside the package's territory; one into a
/// package the configuration does not depend on is a hidden edge (BGR8),
/// found by comparing the reach's packages with the recipe's dependencies.
@("build_primitives.workspace.input_sets.InputSets.reachesAndHiddenEdges")
@safe
unittest
{
    auto f = fixture();
    string name(size_t set)
    {
        const k = f.sets.key(set);
        return text(f.graph.packages[k.package_].shortName, k.configuration.length ? ":" : "", k.configuration);
    }

    string[] reached;
    foreach (ref r; f.sets.reaches(f.graph))
        reached ~= text(name(r.set), " ", r.root, " ", r.into.map!(q => f.graph.packages[q].shortName));
    assert(reached == [
        `counters:unittest libs/harness/src ["harness"]`,
        `ui:gpu-effects docs/specs/ui []`,
        `ui:library docs/specs/ui []`,
        `ui:unittest docs/specs/ui []`,
        `ui:unittest libs/dql/src ["dql"]`,
    ], reached.text);

    string[] hidden;
    foreach (ref h; f.sets.hiddenReaches(f.graph))
        hidden ~= text(name(h.set), " ", h.root, " ", f.graph.packages[h.package_].shortName);
    assert(hidden == ["counters:unittest libs/harness/src harness", "ui:unittest libs/dql/src dql"], hidden.text);

    // A dependency, at the top level or in the configuration, declares the
    // reach.
    const recipes = [
        recipe("libs/harness", `name "harness"`),
        recipe("libs/counters", `name "counters"
dependency "sparkles:harness" path="../.."
configuration "unittest" {
    sourcePaths "../harness/src"
}`),
        recipe("libs/dql", `name "dql"`),
        recipe("libs/ui", `name "ui"
configuration "unittest" {
    sourcePaths "../dql/src"
    dependency "sparkles:dql" path="../.."
}`),
    ];
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
    auto declared = inputSets(graph, recipes, linux, WorkspaceInputs.init);
    assert(declared.reaches(graph).length == 2);
    assert(declared.hiddenReaches(graph).length == 0);
}

/// What planning read is a workspace input unless a package claims it: the
/// root recipe and the lockfiles are, a sub-package's recipe is its own.
@("build_primitives.workspace.input_sets.inputSets.readFilesNoSetClaims")
@safe
unittest
{
    auto f = fixture(WorkspaceInputs(read: ["dub.sdl", "dub.selections.json", "libs/base/dub.sdl", "libs/ui/dub.sdl"],
        patterns: ["flake.lock", "nix/shells/**"]));
    assert(f.sets.inWorkspace("dub.sdl"));
    assert(f.sets.inWorkspace("dub.selections.json"));
    assert(!f.sets.inWorkspace("libs/base/dub.sdl"));
    assert(f.claimants("libs/base/dub.sdl") == ["base"]);
    assert(!f.sets.inWorkspace("libs/ui/dub.sdl"));
    // The toolchain's definition is stated, as no plan reads it.
    assert(f.sets.inWorkspace("flake.lock"));
    assert(f.sets.inWorkspace("nix/shells/default.nix"));
    // A read file is one path, not a pattern.
    assert(!f.sets.inWorkspace("dub.sdl.orig"));
    assert(!f.sets.inWorkspace("docs/dub.sdl"));
}

/// A C source includes from its own directory, so the directory is read
/// whole; a package with no recipe is reported, never given an empty set.
@("build_primitives.workspace.input_sets.inputSets.cSourcesAndMissingRecipes")
@safe
unittest
{
    const recipes = [
        recipe("libs/shaping", `name "shaping"
sourcePaths "d"
importPaths "d"
sourceFiles "c/impl.c" "gen/*.d"
cSourcePaths "csrc"
dflags "-preview=in" "-Ivendor/include"
lflags "-L/opt/lib" "--export-dynamic"`),
        recipe("libs/other", `name "other"`),
    ];
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
    auto sets = inputSets(graph, recipes, linux, WorkspaceInputs.init);
    const shaping = sets.indexOf(ConfiguredPackage(cast(uint) graph.indexOf(PackageId("sparkles:shaping")), ""));
    // A package that declares no configuration answers for dub's default.
    assert(sets.indexOf(ConfiguredPackage(sets.key(shaping).package_, "library")) == shaping);

    assert(sets.compiles(shaping, "libs/shaping/c/impl.c"));
    assert(!sets.compiles(shaping, "libs/shaping/c/local.h"));
    assert(sets.compiles(shaping, "libs/shaping/csrc/deep/x.c"));
    // A named source file may be a glob.
    assert(sets.compiles(shaping, "libs/shaping/gen/a.d"));
    assert(!sets.compiles(shaping, "libs/shaping/gen/deep/a.d"));
    // Flags that carry a path are reported, and make the set opaque.
    assert(sets.opaque.map!(o => o.value).array == ["-Ivendor/include", "-L/opt/lib"]);
    assert(sets.opaque.map!(o => o.reason).array == [OpaqueReason.pathFlag, OpaqueReason.pathFlag]);
    assert(sets.isOpaque(shaping));

    auto partial = inputSets(graph, recipes[0 .. 1], linux, WorkspaceInputs.init);
    const missing = partial.opaque.filter!(o => o.reason == OpaqueReason.noRecipe).array;
    assert(missing.length == 1 && graph.packages[missing[0].package_].shortName == "other");
}

/// Every command dub runs is opaque: those around generating and building,
/// and those around running the target, which `dub test` runs too.
@("build_primitives.workspace.input_sets.inputSets.everyCommandIsOpaque")
@safe
unittest
{
    const recipes = [
        recipe("libs/tool", `name "tool"
preGenerateCommands "a"
postGenerateCommands "b"
preBuildCommands "c"
postBuildCommands "d"
preRunCommands "e"
postRunCommands "f"`),
        recipe("libs/plain", `name "plain"`),
    ];
    const graph = buildPackageGraph("sparkles", recipes, RecipeRole.build, linux).value;
    auto sets = inputSets(graph, recipes, linux, WorkspaceInputs.init);
    assert(sets.opaque.map!(o => text(o.directive, " ", o.reason)).array == [
        "preGenerateCommands command", "postGenerateCommands command", "preBuildCommands command",
        "postBuildCommands command", "preRunCommands command", "postRunCommands command",
    ], sets.opaque.text);
    assert(sets.isOpaque(sets.indexOf(ConfiguredPackage(cast(uint) graph.indexOf(PackageId("sparkles:tool")), ""))));
    assert(!sets.isOpaque(sets.indexOf(ConfiguredPackage(cast(uint) graph.indexOf(PackageId("sparkles:plain")), ""))));
}
