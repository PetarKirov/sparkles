/**
The packages a resolution request reaches, and the configuration each one
builds in (build-graph SPEC BGR2–BGR4).

$(LREF loadProject) reads the request's root recipe and, transitively, every
dependency any configuration names: in-tree subpackages, path dependencies,
and registry packages from a $(LREF RegistrySources) map. It never resolves a
version against a registry. $(LREF packageConfigurations) then picks one
configuration per package as dub's `Project.getPackageConfigs` does: the
graph of every (package, configuration) pair the platform allows, pruned
until each package keeps one.

Copied from dub (`Project.collectDependenciesRec`, `getPackageConfigs`,
`getTopologicalPackageList`, `addTestRunnerConfiguration`); see the
build-graph decisions on behaviour copied from dub's source.
*/
module sparkles.build_primitives.resolve.project;

import std.algorithm.searching : canFind, countUntil, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, replace;
import std.conv : text;
import std.path : buildNormalizedPath, buildPath, dirName, isAbsolute, relativePath;

import sparkles.build_primitives.dub_manifest : DubManifest, DubSubPackage, DubToolchainRequirements,
    parseDubRecipeText;
import sparkles.build_primitives.resolve.driver : ResolveDriver;
import sparkles.build_primitives.resolve.platform : BuildPlatform;
import sparkles.build_primitives.resolve.recipe : ConfigurationTemplate, DependencySpec,
    SettingsTemplate, expandPackageName, fillWithDefaults, packageSettings, toTemplate;
import sparkles.build_primitives.resolve.settings : BuildSettings, TargetType;

/// Thrown inside resolution; the public operations return it as a value.
package class ResolveException : Exception
{
    this(string message) @safe pure nothrow
    {
        super(message);
    }
}

package noreturn fail(string message) @safe pure
{
    throw new ResolveException(message);
}

/// A registry package the DUB locks pin: where its source is, and what the
/// locks say it is.
struct RegistrySource
{
    string directory;   /// the source directory
    string version_;    /// the pinned version, or commit for a repository package
    string repository;  /// a repository package's URL; null for a registry one
}

/// The registry packages, by root name.
alias RegistrySources = RegistrySource[string];

/// In-tree recipe directories, by root package name.
alias InTreeSources = string[string];

/// One package of a project: a recipe, or an inline subpackage of one.
final class Package
{
    string name;        /// the full name: `root` or `root:sub`
    string directory;   /// the package directory, absolute
    string recipe;      /// the recipe file it was read from
    string version_;    /// the recipe's version, if it states one
    /// The tool versions the recipe requires (`toolchainRequirements`).
    DubToolchainRequirements toolchainRequirements;
    Package base;       /// the package whose recipe declares it; itself for a root
    SettingsTemplate settings;             /// the top-level settings
    ConfigurationTemplate[] configurations; /// in declaration order, defaults filled
    SettingsTemplate[string] buildTypes;   /// by name
    /// The subpackages it declares: by name for inline ones, and by
    /// directory for path references.
    private const(DubSubPackage)[] subPackages;

    /// The dependencies of `configuration`: the top level's and the
    /// configuration's, the latter winning.
    DependencySpec[string] dependencies(string configuration) const @safe pure nothrow
    {
        DependencySpec[string] result;
        foreach (name, spec; settings.dependencies)
            result[name] = spec;
        foreach (ref c; configurations)
            if (c.name == configuration)
            {
                foreach (name, spec; c.settings.dependencies)
                    result[name] = spec;
                break;
            }
        return result;
    }

    /// The names of every dependency any configuration names, sorted, unique.
    string[] allDependencyNames() const @safe pure nothrow
    {
        import std.algorithm.iteration : uniq;

        string[] names = settings.dependencies.keys;
        foreach (ref c; configurations)
            names ~= c.settings.dependencies.keys;
        return names.sort.uniq.array;
    }

    /// The configurations that apply on `platform`, in declaration order;
    /// executables only when `allowNonLibrary`. `[null]` when none applies.
    string[] platformConfigurations(const BuildPlatform platform, bool allowNonLibrary = false) const
        @safe pure nothrow
    {
        string[] result;
        foreach (ref c; configurations)
            if (c.matchesPlatform(platform)
                && (allowNonLibrary || c.settings.targetType != TargetType.executable))
                result ~= c.name;
        return result.length ? result : [string.init];
    }

    /// The configuration `configuration` selects for `dependency`, or null.
    string subConfiguration(string configuration, string dependency) const @safe pure nothrow
    {
        foreach (ref c; configurations)
            if (c.name == configuration)
            {
                if (auto selected = dependency in c.settings.subConfigurations)
                    return *selected;
                break;
            }
        if (auto selected = dependency in settings.subConfigurations)
            return *selected;
        return null;
    }

    /// The configuration named `name`, or null.
    inout(ConfigurationTemplate)* configuration(string name) inout @safe pure nothrow @nogc
    {
        foreach (ref c; configurations)
            if (c.name == name)
                return &c;
        return null;
    }

    /// This package's settings for one configuration (`Package.getBuildSettings`).
    BuildSettings buildSettings(const BuildPlatform platform, string configuration, ResolveDriver driver)
        const @safe
        => packageSettings(settings, configurations, configuration, name, platform, directory, driver);
}

/// The packages a request reaches, the root first.
final class Project
{
    Package root;            ///
    Package[string] byName;  /// every package reached, by full name
    private Package[string] byRecipe; // root packages by recipe directory
    private Package[string] subPackages; // subpackages by full name, once read
    private ResolveDriver driver;
    private RegistrySources registry;
    private InTreeSources inTree;
    /// Whether the root is a single-file package.
    bool single;

    /**
    Every package the recipes read so far declare: each root recipe and all
    its subpackages, reached or not, sorted by name. These own the
    directories hidden-edge detection (BGR8) attributes a path to.
    */
    Package[] allDeclared() @safe
    {
        Package[] result;
        foreach (base; byRecipe.values)
        {
            result ~= base;
            foreach (ref s; base.subPackages)
            {
                string name = s.name;
                if (!s.isInline)
                {
                    const directory = buildNormalizedPath(base.directory, s.path);
                    string source;
                    foreach (file; ["dub.sdl", "dub.json", "package.json"])
                        if (driver.readText(directory.buildPath(file), source))
                        {
                            auto parsed = parseDubRecipeText(source, directory.buildPath(file));
                            if (parsed.hasValue)
                                name = parsed.value.name;
                            break;
                        }
                }
                if (name.length)
                    result ~= resolveSubPackage(this, base, name);
            }
        }
        return result.sort!((a, b) => a.name < b.name).release;
    }

    /// The package `name`, or null when the project does not reach it.
    inout(Package) package_(string name) inout @safe pure nothrow
    {
        if (auto found = name in byName)
            return *found;
        return null;
    }

    /**
    The packages in topological order from `start` (the root by default):
    each package before its dependencies, or after them with
    `childrenFirst`. A package's dependencies are those of its configuration
    in `configurations`, or of all its configurations when it has none
    there, visited in name order (`getTopologicalPackageList`).
    */
    Package[] topological(bool childrenFirst = false, const string[string] configurations = null,
        Package start = null) @safe
    {
        Package[] order;
        bool[Package] visited;
        void visit(Package p) @safe
        {
            if (p in visited)
                return;
            visited[p] = true;
            if (!childrenFirst)
                order ~= p;
            const configuration = configurations is null ? null : configurations.get(p.name, null);
            string[] names = configuration.length ? p.dependencies(configuration).keys.sort.release
                : p.allDependencyNames;
            foreach (name; names)
                if (auto dependency = package_(name))
                    visit(dependency);
            if (childrenFirst)
                order ~= p;
        }
        visit(start is null ? root : start);
        return order;
    }
}

/**
Loads the project rooted at the recipe in `directory`, or at its subpackage
`subPackage` (`:base` or `base`), reaching every dependency.

`inTree` maps root package names to recipe directories: a dependency on one
of them by version resolves to that directory, as a documentation example's
`version="*"` dependency on this repository does when the requester asks.
*/
Project loadProject(string directory, string subPackage, ResolveDriver driver,
    RegistrySources registry, InTreeSources inTree = null) @safe
{
    auto project = new Project;
    project.driver = driver;
    project.registry = registry;
    project.inTree = inTree;
    auto base = loadRecipe(project, buildNormalizedPath(directory), null);
    project.root = subPackage.length
        ? resolveSubPackage(project, base, subPackage.startsWith(":") ? subPackage[1 .. $] : subPackage)
        : base;
    collectDependencies(project, project.root);
    return project;
}

/**
Loads the project rooted at a single-file package (BGR6): a D source whose
leading `/+ dub.sdl: … +/` comment is its recipe, and which is its only
source, as dub's `loadSingleFilePackage` makes it.
*/
Project loadSingleFileProject(string file, ResolveDriver driver, RegistrySources registry,
    InTreeSources inTree = null) @safe
{
    import std.path : baseName, stripExtension;

    auto project = new Project;
    project.driver = driver;
    project.registry = registry;
    project.inTree = inTree;
    file = buildNormalizedPath(file);
    string source;
    if (!driver.readText(file, source))
        fail(text("cannot read ", file));
    auto parsed = parseDubRecipeText(source, file);
    if (parsed.hasError)
        fail(parsed.error.text);
    DubManifest manifest = parsed.value;
    if (manifest.name.length == 0)
        manifest.name = file.baseName.stripExtension;
    foreach (setting; [manifest.sourceFiles, manifest.sourcePaths, manifest.cSourcePaths,
            manifest.importPaths, manifest.cImportPaths])
        if (setting.length)
            fail(text(file, ": a single-file package states no source or import paths"));

    auto p = makePackage(project, manifest, manifest.name, file.dirName, file, fillDefaults: false);
    p.settings.sourceFiles[""] = null;
    p.settings.sourcePaths[""] = null;
    p.settings.cSourcePaths[""] = null;
    p.settings.importPaths[""] = null;
    p.settings.cImportPaths[""] = null;
    p.settings.mainSourceFile = file;
    if (p.settings.targetType == TargetType.autodetect)
        p.settings.targetType = TargetType.executable;
    fillWithDefaults(p.settings, p.configurations, p.name, p.directory, driver);
    p.base = p;
    project.root = p;
    project.single = true;
    collectDependencies(project, p);
    return project;
}

// Reads the root recipe in `directory`, once per directory.
private Package loadRecipe(Project project, string directory, string expectedName) @safe
{
    if (auto loaded = directory in project.byRecipe)
        return *loaded;
    string recipe, source;
    foreach (file; ["dub.sdl", "dub.json", "package.json"])
        if (project.driver.readText(directory.buildPath(file), source))
        {
            recipe = directory.buildPath(file);
            break;
        }
    if (recipe is null)
        fail(text("no DUB recipe in ", directory));
    auto parsed = parseDubRecipeText(source, recipe);
    if (parsed.hasError)
        fail(parsed.error.text);
    const manifest = parsed.value;
    if (manifest.name.length == 0)
        fail(text(recipe, ": the package has no name"));
    if (expectedName.length && manifest.name != expectedName)
        fail(text(recipe, ": expected package `", expectedName, "`, found `", manifest.name, "`"));

    auto p = makePackage(project, manifest, manifest.name, directory, recipe);
    p.base = p;
    p.subPackages = manifest.subPackages;
    project.byRecipe[directory] = p;
    return p;
}

// A package from a recipe, or from an inline subpackage's block.
private Package makePackage(R)(Project project, const ref R recipe, string name, string directory,
    string recipeFile, bool fillDefaults = true) @safe
{
    auto p = new Package;
    p.name = name;
    p.directory = directory;
    p.recipe = recipeFile;
    p.version_ = recipe.version_;
    static foreach (tool; ["dub", "frontend", "dmd", "ldc", "gdc"])
        __traits(getMember, p.toolchainRequirements, tool) = __traits(getMember, recipe.toolchainRequirements, tool);
    string error;
    if (!toTemplate(recipe, name, p.settings, error))
        fail(text(recipeFile, ": ", error));
    foreach (ref c; recipe.configurations)
    {
        ConfigurationTemplate configuration;
        configuration.name = c.name;
        configuration.platforms = c.platforms.dup;
        if (!toTemplate(c, name, configuration.settings, error))
            fail(text(recipeFile, ": configuration `", c.name, "`: ", error));
        p.configurations ~= configuration;
    }
    foreach (ref b; recipe.buildTypes)
    {
        SettingsTemplate settings;
        if (!toTemplate(b, name, settings, error))
            fail(text(recipeFile, ": build type `", b.name, "`: ", error));
        p.buildTypes[b.name] = settings;
    }
    if (fillDefaults)
        fillWithDefaults(p.settings, p.configurations, name, directory, project.driver);
    return p;
}

// The subpackage `sub` of `base`: an inline block named `sub`, or the path
// reference whose recipe is named `sub`.
private Package resolveSubPackage(Project project, Package base, string sub) @safe
{
    const fullName = base.name ~ ":" ~ sub;
    if (auto loaded = fullName in project.subPackages)
        return *loaded;
    foreach (ref s; base.subPackages)
    {
        Package p;
        if (s.isInline)
        {
            if (s.name != sub)
                continue;
            p = makePackage(project, s, fullName, base.directory, base.recipe);
        }
        else
        {
            const directory = buildNormalizedPath(base.directory, s.path);
            string recipe, source;
            foreach (file; ["dub.sdl", "dub.json", "package.json"])
                if (project.driver.readText(directory.buildPath(file), source))
                {
                    recipe = directory.buildPath(file);
                    break;
                }
            if (recipe is null)
                fail(text(base.recipe, ": no DUB recipe for the subpackage in ", directory));
            auto parsed = parseDubRecipeText(source, recipe);
            if (parsed.hasError)
                fail(parsed.error.text);
            if (parsed.value.name != sub)
                continue;
            const manifest = parsed.value;
            if (manifest.subPackages.length)
                fail(text(recipe, ": a subpackage cannot declare subpackages"));
            p = makePackage(project, manifest, fullName, directory, recipe);
        }
        p.base = base;
        project.subPackages[fullName] = p;
        return p;
    }
    return fail(text("the package `", base.name, "` (", base.recipe, ") has no subpackage `", sub, "`"));
}

// dub's `collectDependenciesRec`: every dependency of every configuration.
private void collectDependencies(Project project, Package p) @safe
{
    project.byName[p.name] = p;
    foreach (name; p.allDependencyNames)
    {
        if (name in project.byName)
            continue;
        DependencySpec spec;
        foreach (ref c; [p.settings] ~ configurationSettings(p))
            if (auto s = name in c.dependencies)
            {
                spec = *s;
                break;
            }
        // dub uses an optional dependency only when it is selected; the
        // locks select none, so only an optional-by-default one is used.
        if (spec.optional && !spec.default_)
            continue;
        auto dependency = loadDependency(project, p, name, spec);
        if (dependency.name !in project.byName)
            collectDependencies(project, dependency);
    }
}

private SettingsTemplate[] configurationSettings(Package p) @safe pure nothrow
{
    SettingsTemplate[] result;
    foreach (ref c; p.configurations)
        result ~= c.settings;
    return result;
}

// The package a dependency names, loading its recipe.
private Package loadDependency(Project project, Package from, string name, const DependencySpec spec) @safe
{
    import std.string : indexOf;

    const colon = name.indexOf(':');
    const rootName = colon < 0 ? name : name[0 .. colon];
    const sub = colon < 0 ? null : name[colon + 1 .. $];

    Package base;
    if (rootName == project.root.base.name)
        base = project.root.base;
    // A package's own subpackage is the same package, at its version: dub
    // checks no range for it.
    else if (rootName == from.base.name)
        base = from.base;
    else if (spec.path.length && spec.repository.length == 0)
        base = loadRecipe(project, buildNormalizedPath(from.directory, spec.path), rootName);
    else if (auto tree = rootName in project.inTree)
        base = loadRecipe(project, buildNormalizedPath(*tree), rootName);
    // A repository dependency is pinned by the locks like a registry one,
    // and the locks must pin what the recipe asks for.
    else if (auto source = rootName in project.registry)
    {
        checkLocked(from, name, spec, *source);
        base = loadRecipe(project, buildNormalizedPath(source.directory), rootName);
    }
    else
        fail(text(from.recipe, ": the dependency `", name, "` is in neither DUB lock"));
    return sub.length ? resolveSubPackage(project, base, sub) : base;
}

// Fails unless the locked `source` is what `spec` asks for: the same
// repository and commit, or a version in the range.
private void checkLocked(Package from, string name, const DependencySpec spec, const RegistrySource source)
    @safe
{
    import sparkles.build_primitives.resolve.dub_versions : dubRangeAllows;

    static string bare(string url) @safe pure nothrow
        => url.startsWith("git+") ? url[4 .. $] : url;

    if (spec.repository.length)
    {
        if (bare(spec.repository) != bare(source.repository) || spec.version_ != source.version_)
            fail(text(from.recipe, ": `", name, "` asks for ", spec.repository, " at ", spec.version_,
                "; the locks pin ", source.repository, " at ", source.version_));
        return;
    }
    string error;
    if (!dubRangeAllows(spec.version_, source.version_, error))
        fail(text(from.recipe, ": `", name, "` asks for ", spec.version_, "; the locks pin ",
            source.version_, error.length ? " (" ~ error ~ ")" : ""));
}

/**
The configuration each package of `project` builds in when its root builds
in `rootConfiguration` (or, when that is null, in its default one), as dub's
`getPackageConfigs`.
*/
string[string] packageConfigurations(Project project, const BuildPlatform platform,
    string rootConfiguration, bool allowNonLibrary = true) @safe
{
    static struct Info
    {
        Package package_;
        size_t[] parents;
        string name;
        string[] dependencies;
    }

    Info[] packages;
    size_t[string] indexOf;
    foreach (p; project.topological)
    {
        indexOf[p.name] = packages.length;
        packages ~= Info(p, null, p.name, p.allDependencyNames);
    }
    foreach (i, ref info; packages)
        foreach (d; info.dependencies)
            if (auto pi = d in indexOf)
                packages[*pi].parents ~= i;

    static struct Vertex
    {
        size_t pack = size_t.max;
        string config;
    }

    static struct Edge
    {
        size_t from, to;
    }

    Vertex[] configs;
    bool[Vertex] configSet;
    Edge[] edges;

    size_t createConfig(size_t pack, string config)
    {
        foreach (i, v; configs)
            if (v.pack == pack && v.config == config)
                return i;
        configs ~= Vertex(pack, config);
        configSet[Vertex(pack, config)] = true;
        return configs.length - 1;
    }

    bool haveConfig(size_t pack, string config) => (Vertex(pack, config) in configSet) !is null;

    void removeConfig(size_t index) @safe
    {
        auto hadDependency = new bool[configs.length];
        auto stillHasDependency = new bool[configs.length];
        Edge[] kept;
        foreach (e; edges)
        {
            if (e.to == index)
            {
                hadDependency[e.from] = true;
                continue;
            }
            if (configs[e.to].pack == configs[index].pack)
                stillHasDependency[e.from] = true;
            if (e.from != index)
                kept ~= e;
        }
        edges = kept;
        configSet.remove(configs[index]);
        configs[index] = Vertex.init;
        foreach (j; 0 .. configs.length)
            if (j != index && hadDependency[j] && !stillHasDependency[j])
                removeConfig(j);
    }

    auto reachable = new bool[packages.length];
    bool reachableByAllParents(size_t index)
    {
        foreach (p; packages[configs[index].pack].parents)
            reachable[p] = false;
        foreach (e; edges)
            if (e.to == index)
                reachable[configs[e.from].pack] = true;
        foreach (p; packages[configs[index].pack].parents)
            if (!reachable[p])
                return false;
        return true;
    }

    auto dependencyConfigs = new string[][](packages.length);
    void determineDependencyConfigs(size_t pack, string c)
    {
        bool[Edge] edgeSet;
        void createEdge(size_t from, size_t to)
        {
            if (Edge(from, to) in edgeSet)
                return;
            edges ~= Edge(from, to);
            edgeSet[Edge(from, to)] = true;
        }

        auto info = &packages[pack];
        if (haveConfig(pack, c) && !(rootConfiguration.length && info.name == project.root.name
                && rootConfiguration == c))
            return;

        foreach (d; info.dependencies)
        {
            const dp = indexOf.get(d, size_t.max);
            if (dp == size_t.max)
                continue;
            dependencyConfigs[dp] = null;
            void setConfigs(string[] candidates)
            {
                foreach (candidate; candidates)
                    if (haveConfig(dp, candidate))
                        dependencyConfigs[dp] ~= candidate;
            }

            const selected = info.package_.subConfiguration(c, packages[dp].name);
            if (selected.length)
                setConfigs([selected]);
            else
            {
                setConfigs(packages[dp].package_.platformConfigurations(platform));
                if (dependencyConfigs[dp].length == 0)
                    setConfigs(packages[dp].package_.platformConfigurations(platform, true));
            }
            if (dependencyConfigs[dp].length == 0)
                return;
        }

        const index = createConfig(pack, c);
        foreach (d; info.dependencies)
            if (auto pdp = d in indexOf)
                foreach (sc; dependencyConfigs[*pdp])
                    createEdge(index, createConfig(*pdp, sc));
    }

    string[] path;
    void determineAllConfigs(size_t pack) @safe
    {
        auto info = &packages[pack];
        const cycle = path.countUntil(info.name);
        if (cycle >= 0)
        {
            import std.array : join;

            fail(text("dependency cycle: ", (path[cycle .. $] ~ info.name).join(" -> ")));
        }
        path ~= info.name;
        scope (exit)
            path = path[0 .. $ - 1];
        foreach (d; info.dependencies)
            if (auto pi = d in indexOf)
                determineAllConfigs(*pi);
        foreach (c; info.package_.platformConfigurations(platform, allowNonLibrary))
            determineDependencyConfigs(pack, c);
    }

    if (rootConfiguration.length)
        createConfig(0, rootConfiguration);
    determineAllConfigs(0);

    bool changed;
    do
    {
        changed = false;
        foreach (i, ref c; configs)
        {
            if (c == Vertex.init)
                continue;
            if (!reachableByAllParents(i))
            {
                removeConfig(i);
                changed = true;
            }
        }
        if (!changed)
            foreach (pack; 0 .. packages.length)
            {
                size_t count;
                foreach (i, ref c; configs)
                    if (c.pack == pack && ++count > 1)
                        removeConfig(i);
                if (count > 1)
                {
                    changed = true;
                    break;
                }
            }
    }
    while (changed);

    string[string] result;
    foreach (c; configs)
    {
        if (c == Vertex.init)
            continue;
        const name = packages[c.pack].name;
        if (auto existing = name in result)
            if (*existing != c.config)
                fail(text("conflicting configurations for `", name, "`: ", *existing, " and ", c.config));
        result[name] = c.config;
    }

    auto visited = new bool[packages.length];
    void check(size_t pack) @safe
    {
        if (visited[pack])
            return;
        visited[pack] = true;
        const name = packages[pack].name;
        auto configuration = name in result;
        if (configuration is null)
            fail(text("no configuration of `", name, "` satisfies every package depending on it"));
        foreach (d, spec; packages[pack].package_.dependencies(*configuration))
            if (auto pi = d in indexOf)
                check(*pi);
    }
    check(0);
    return result;
}

/// The default configuration of `project`'s root: its first applicable one,
/// libraries only unless `allowNonLibrary` (`Project.getDefaultConfiguration`).
string defaultConfiguration(Project project, const BuildPlatform platform, bool allowNonLibrary = true) @safe
    => packageConfigurations(project, platform, null, allowNonLibrary).get(project.root.name, null);

/// What a test root adds to its project: the configuration it builds in,
/// and the root's sources the generated test-root module imports.
struct TestRoot
{
    /// The configuration to resolve: the generated `<name>-test-<base>`
    /// one, or the base configuration itself when that is already an
    /// executable `unittest` one (dub then generates nothing).
    string configuration;
    /// Whether the configuration is generated, and so needs a test-root
    /// module as its main source file.
    bool generated;
    /// The root's D sources, relative to its directory, that the test root
    /// imports: every one but the main file and `package.d` files.
    string[] testedSources;
}

/**
Adds the test-runner configuration `dub test` builds to `project`'s root, as
dub's `addTestRunnerConfiguration` does, without writing the main file: the
test-root module is generated later, from `TestRoot.testedSources`.
*/
TestRoot addTestRunnerConfiguration(Project project, const BuildPlatform platform) @safe
{
    import std.path : baseName;

    auto root = project.root;
    string baseConfiguration = root.configuration("unittest") !is null ? "unittest" : null;
    if (baseConfiguration is null)
        baseConfiguration = defaultConfiguration(project, platform, false);
    if (baseConfiguration is null)
        baseConfiguration = defaultConfiguration(project, platform, true);

    const settings = root.buildSettings(platform, baseConfiguration, project.driver);
    if (settings.targetType == TargetType.none)
        fail(text("the configuration `", baseConfiguration, "` of `", root.name, "` has target type none"));
    if (settings.targetType == TargetType.executable && baseConfiguration == "unittest")
        return TestRoot(baseConfiguration, false);
    if (settings.sourceFiles.length == 0)
        return TestRoot(defaultConfiguration(project, platform), false);

    const name = text(root.name.replace(".", "-").replace(":", "-"), "-test-", baseConfiguration);
    auto base = root.configuration(baseConfiguration);
    ConfigurationTemplate testConfiguration;
    testConfiguration.name = name;
    // dub's generated configuration keeps the base's settings, not its
    // platform restriction.
    if (base !is null)
        testConfiguration = ConfigurationTemplate(name, null, deepCopy(base.settings));
    testConfiguration.copiedFrom = baseConfiguration;
    testConfiguration.settings.targetType = TargetType.executable;
    if (testConfiguration.settings.targetName.length == 0 || baseConfiguration != "unittest")
        testConfiguration.settings.targetName = name;

    string mainFile = testConfiguration.settings.mainSourceFile;
    if (mainFile.length == 0)
        mainFile = root.settings.mainSourceFile;
    if (mainFile.isAbsolute)
        mainFile = relativePath(mainFile, root.directory);

    TestRoot result = TestRoot(name, true);
    foreach (file; settings.sourceFiles)
    {
        if (!file.endsWith(".d"))
            continue;
        // A single-file package's main file is its only source: dub keeps it.
        if (!project.single && mainFile.length && buildNormalizedPath(file) == buildNormalizedPath(mainFile))
        {
            testConfiguration.settings.excludedSourceFiles.require("", null) ~= mainFile;
            continue;
        }
        if (file.baseName == "package.d")
            continue;
        result.testedSources ~= file;
    }
    root.configurations ~= testConfiguration;
    return result;
}

// A copy of `t` whose groups can be appended to without touching `t`'s.
private SettingsTemplate deepCopy(const SettingsTemplate t) @safe pure nothrow
{
    import sparkles.build_primitives.resolve.recipe : listSettings;

    SettingsTemplate copy;
    foreach (k, v; t.dependencies)
        copy.dependencies[k] = v;
    foreach (k, v; t.subConfigurations)
        copy.subConfigurations[k] = v;
    copy.targetType = t.targetType;
    copy.targetPath = t.targetPath;
    copy.targetName = t.targetName;
    copy.workingDirectory = t.workingDirectory;
    copy.mainSourceFile = t.mainSourceFile;
    static foreach (name; listSettings ~ ["sourcePaths", "cSourcePaths"])
        foreach (k, v; __traits(getMember, t, name))
            __traits(getMember, copy, name)[k] = v.dup;
    static foreach (name; ["environments", "buildEnvironments", "runEnvironments"])
        foreach (k, v; __traits(getMember, t, name))
            foreach (key, value; v)
                __traits(getMember, copy, name)[k][key] = value;
    foreach (k, v; t.buildRequirements)
        copy.buildRequirements[k] = v;
    foreach (k, v; t.buildOptions)
        copy.buildOptions[k] = v;
    return copy;
}
