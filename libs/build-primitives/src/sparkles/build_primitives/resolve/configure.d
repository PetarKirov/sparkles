/**
Resolved settings for every target of a request (build-graph SPEC BGR3):
dub's `ProjectGenerator.generate` up to the point where it hands targets to a
generator, with `configurePackages`' steps in dub's order.

$(LREF resolve) is the operation SPEC §11 names: a recipe, a configuration, a
build type and a platform, to the resolved settings of each binary target,
the root first. Paths in the result are absolute and normalized.

Copied from dub (`ProjectGenerator.generate`, `configurePackages`,
`mergeFromDependent`, `mergeFromDependency`, `addBuildTypeSettings`,
`Project.addBuildTypeSettings`, `processVars` and `getVariable`); see the
build-graph decisions on behaviour copied from dub's source.
*/
module sparkles.build_primitives.resolve.configure;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.conv : text;
import std.path : buildNormalizedPath, extension, isAbsolute;

import sparkles.build_primitives.resolve.driver : ResolveDriver;
import sparkles.build_primitives.resolve.platform : BuildPlatform, matchesSpecification;
import sparkles.build_primitives.resolve.project : InTreeSources, Package, Project, RegistrySources, loadSingleFileProject,
    ResolveException, TestRoot, addTestRunnerConfiguration, defaultConfiguration, fail,
    loadProject, packageConfigurations;
import sparkles.build_primitives.resolve.hidden_edges : HiddenEdge, PackageLocation, hiddenEdges;
import sparkles.build_primitives.resolve.recipe : applyTemplate;
import sparkles.build_primitives.resolve.settings : BuildOption, BuildSettings, TargetType,
    abiCriticalFlags, enforceBuildRequirements, extractBuildOptions, haveVersion,
    inheritedBuildOptions;
import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;



/// How versions pass from a dependent down to its dependencies (D13).
enum VersionInheritance
{
    /// As dub: every version and debug version passes down. Pruning
    /// (BGV1) happens when variants are keyed, not here.
    faithful,
    /// A dependent's configuration-level versions and debug versions (those
    /// its selected configuration's block adds on this platform) do not pass
    /// down; build-type options and ABI-critical flags still do. The lint
    /// that rejects a dependency testing one needs the source lexer of
    /// version pruning, and comes with it.
    divergent,
}

/// One resolution request.
struct ResolveRequest
{
    /// The directory of the package's recipe; for a subpackage, that of the
    /// recipe declaring it.
    string directory;
    /// The subpackage to resolve (`:base`), or null for the recipe's own package.
    string subPackage;
    /// The root's configuration; null for its default one. Ignored for a test root.
    string configuration;
    /// The build type, resolved against the root's recipe.
    string buildType = "debug";
    /// The platform resolved for.
    BuildPlatform platform;
    /// Whether to resolve the test runner `dub test` builds.
    bool testRoot;
    /// How versions pass down.
    VersionInheritance inheritance;
    /// The source directory of each registry package.
    RegistrySources registry;
    /// What `$DUB` expands to.
    string dubExecutable = "dub";
    /// A single-file package to resolve (BGR6), instead of `directory`.
    string singleFile;
    /// The dub version `toolchainRequirements dub=…` is checked against;
    /// null to check none.
    string dubVersion;
    /// Root package names whose dependencies by version resolve to the
    /// given in-tree recipe directory (BGR6).
    InTreeSources inTree;
}

/// One binary target, or the root of one.
struct ResolvedTarget
{
    string package_;        /// the package's full name
    string configuration;   /// the configuration it builds in
    string directory;       /// the package directory
    /// The packages compiled into it: itself, then the source libraries it folds in.
    string[] packages;
    string[] dependencies;     /// its direct binary dependencies
    string[] linkDependencies; /// every binary it links, in link order
    BuildSettings settings;    /// the resolved settings
}

/// What a request resolves to.
struct Resolution
{
    string rootPackage;     ///
    string configuration;   /// the root's configuration
    string buildType;       ///
    /// The configuration of every package reached, source libraries included.
    string[string] configurations;
    /// The binary targets, the root first, then in dependency order.
    ResolvedTarget[] targets;
    /// For a test root, what its generated module imports.
    TestRoot testRoot;
    /**
    The environment variables the resolved values refer to, `DFLAGS`
    included when dub would read it, sorted. Values move between targets
    (up, down, and from the root's build type into every target), so each
    is taken as an input of every target: a conservative reading of BGR2.
    */
    string[] environmentInputs;
    /// The reaches into another package's directory without a dependency
    /// on it, of every package reached (BGR8).
    HiddenEdge[] hiddenEdges;

    /// The target of `packageName`, or null.
    inout(ResolvedTarget)* target(string packageName) inout @safe pure nothrow @nogc
    {
        foreach (ref t; targets)
            if (t.package_ == packageName)
                return &t;
        return null;
    }
}

/// Why a request cannot be resolved.
struct ResolveError
{
    string message; ///

    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;

        put(w, message);
    }
}

/// Resolves `request`, reading through `driver`.
PlanExpected!(Resolution, ResolveError) resolve(const ResolveRequest request, ResolveDriver driver) @safe
{
    import std.path : isAbsolute;

    if (request.singleFile.length ? !request.singleFile.isAbsolute : !request.directory.isAbsolute)
        return planErr!Resolution(ResolveError(text("the request's path must be absolute: ",
            request.singleFile.length ? request.singleFile : request.directory)));
    try
        return planOk!ResolveError(resolveOrThrow(request, driver));
    catch (ResolveException e)
        return planErr!Resolution(ResolveError(e.msg));
    // A Phobos path or conversion function rejecting a value the recipe
    // states is a resolution error too.
    catch (Exception e)
        return planErr!Resolution(ResolveError(e.msg));
}

private struct TargetInfo
{
    Package package_;
    Package[] packages;
    string configuration;
    BuildSettings settings;
    string[] dependencies;
    string[] linkDependencies;
    // For the divergent mode: the versions and debug versions only the
    // selected configuration's block states, on this platform.
    string[] configurationVersions;
    string[] configurationDebugVersions;
}

// The versions and debug versions `configuration`'s block of `p` adds to
// what its top level states, `-version=` dflags included.
private void configurationOnlyVersions(Package p, string configuration, const BuildPlatform platform,
    ResolveDriver driver, out string[] versions, out string[] debugVersions) @safe
{
    auto block = p.configuration(configuration);
    if (block is null)
        return;
    BuildSettings top, own;
    applyTemplate(p.settings, top, platform, p.directory, driver);
    applyTemplate(block.settings, own, platform, p.directory, driver);
    top.extractBuildOptions("dmd");
    own.extractBuildOptions("dmd");
    versions = own.versions.filter!(v => !top.versions.canFind(v)).array;
    debugVersions = own.debugVersions.filter!(v => !top.debugVersions.canFind(v)).array;
}

private Resolution resolveOrThrow(ref const ResolveRequest request, ResolveDriver driver) @safe
{
    RegistrySources registry;
    foreach (name, dir; request.registry)
        registry[name] = dir;
    InTreeSources inTree;
    foreach (name, dir; request.inTree)
        inTree[name] = dir;
    auto project = request.singleFile.length
        ? loadSingleFileProject(request.singleFile, driver, registry, inTree)
        : loadProject(request.directory, request.subPackage, driver, registry, inTree);
    const platform = request.platform;

    Resolution resolution;
    resolution.rootPackage = project.root.name;
    resolution.buildType = request.buildType;

    string configuration = request.configuration;
    if (request.testRoot)
    {
        resolution.testRoot = addTestRunnerConfiguration(project, platform);
        configuration = resolution.testRoot.configuration;
    }
    if (configuration.length == 0)
        configuration = defaultConfiguration(project, platform);
    if (configuration.length && project.root.configuration(configuration) is null)
        fail(text("`", project.root.name, "` has no configuration `", configuration, "`"));
    resolution.configuration = configuration;

    auto configurations = packageConfigurations(project, platform, configuration);
    resolution.configurations = configurations;
    foreach (p; project.topological(false, configurations))
        checkToolchain(p, platform, request.dubVersion);

    auto variables = Variables(project, request, driver, configurations);

    TargetInfo[string] targets;
    foreach (p; project.topological(true, configurations))
    {
        const c = configurations[p.name];
        auto raw = p.buildSettings(platform, c, driver);
        BuildSettings processed;
        processVars(processed, p, raw, variables, true);
        auto ti = TargetInfo(p, [p], c, processed);
        if (request.inheritance == VersionInheritance.divergent)
            configurationOnlyVersions(p, c, platform, driver, ti.configurationVersions,
                ti.configurationDebugVersions);
        targets[p.name] = ti;
    }

    configurePackages(project, targets, request, variables);

    foreach (ref ti; targets.byValue)
    {
        addBuildTypeSettings(project, ti, request, variables);
        enforceBuildRequirements(ti.settings);
    }

    foreach (p; project.topological(false, configurations))
        if (auto ti = p.name in targets)
            resolution.targets ~= ResolvedTarget(p.name, ti.configuration, p.directory,
                ti.packages.map!(q => q.name).array, ti.dependencies, ti.linkDependencies,
                ti.settings);
    resolution.environmentInputs = variables.environmentInputs.sort.release;

    // Every package directory the request's tree declares, and the
    // registry's, own their files; a reach into one needs a dependency.
    PackageLocation[] locations;
    foreach (p; project.allDeclared)
        locations ~= PackageLocation(p.name, p.directory);
    foreach (name, directory; registry)
        locations ~= PackageLocation(name, directory.directory);
    foreach (p; project.topological(false, configurations))
        resolution.hiddenEdges ~= hiddenEdges(p, locations, driver);
    return resolution;
}

// dub's `checkPlatform` and `checkDubRequirements`: the compiler, frontend and
// dub versions each package's `toolchainRequirements` admit. `no` admits none.
private void checkToolchain(Package p, const BuildPlatform platform, string dubVersion) @safe
{
    import sparkles.build_primitives.resolve.dub_versions : dubRangeAllows;

    void check(string tool, string range, string version_)
    {
        if (range.length == 0 || version_.length == 0)
            return;
        string error;
        const allowed = range != "no" && dubRangeAllows(range, version_, error);
        if (!allowed)
            fail(text("`", p.name, "` requires ", tool, " ", range, "; resolving for ", tool, " ",
                version_, error.length ? " (" ~ error ~ ")" : ""));
    }

    const t = p.toolchainRequirements;
    check("dub", t.dub, dubVersion);
    if (platform.frontendVersion > 0)
        check("frontend", t.frontend,
            text(platform.frontendVersion / 1000, ".", platform.frontendVersion % 1000, ".0"));
    switch (platform.compiler)
    {
    case "dmd": check("dmd", t.dmd, platform.compilerVersion); break;
    case "ldc": check("ldc", t.ldc, platform.compilerVersion); break;
    case "gdc": check("gdc", t.gdc, platform.compilerVersion); break;
    default: break;
    }
}

// dub's `configurePackages`: target types, the collection of dependencies
// with source libraries folded in, then down, across, up, string imports.
private void configurePackages(Project project, ref TargetInfo[string] targets,
    ref const ResolveRequest request, ref Variables variables) @safe
{
    auto root = project.root;
    const platform = request.platform;

    TargetType determineTargetType(ref TargetInfo ti) @safe
    {
        TargetType type = ti.settings.targetType;
        if (type == TargetType.autodetect || type == TargetType.library)
            type = TargetType.staticLibrary;
        if (type != TargetType.none && type != TargetType.sourceLibrary && ti.settings.sourceFiles.length == 0)
            type = TargetType.none;
        return type;
    }

    string[] mainSourceFiles;
    bool[string] hasOutput;
    foreach (ref ti; targets.byValue)
    {
        auto bs = &ti.settings;
        bs.targetType = determineTargetType(ti);
        final switch (bs.targetType)
        {
        case TargetType.none:
            *bs = BuildSettings.init;
            bs.targetType = TargetType.none;
            break;
        case TargetType.executable:
            break;
        case TargetType.dynamicLibrary:
            bs.options |= BuildOption.pic;
            goto case TargetType.staticLibrary;
        case TargetType.autodetect:
        case TargetType.library:
        case TargetType.sourceLibrary:
        case TargetType.staticLibrary:
        case TargetType.object:
            if (bs.mainSourceFile.length)
            {
                const main = bs.mainSourceFile;
                bs.sourceFiles = bs.sourceFiles.filter!(f => f != main).array;
                mainSourceFiles ~= main;
            }
            break;
        }
        const generatesBinary = bs.targetType != TargetType.sourceLibrary && bs.targetType != TargetType.none;
        hasOutput[ti.package_.name] = generatesBinary || ti.package_ is root;
    }

    auto rootTarget = &targets[root.name];
    if (rootTarget.settings.targetType == TargetType.executable || project.single)
        rootTarget.settings.addSourceFiles(mainSourceFiles);

    bool[Package] visited;
    void collectDependencies(Package p, ref TargetInfo ti) @safe
    {
        if (p in visited)
            return;
        if (hasOutput[p.name])
            visited[p] = true;
        auto dependencies = p.dependencies(targets[p.name].configuration);
        foreach (name; dependencies.keys.sort)
        {
            auto dependency = project.package_(name);
            if (dependency is null)
                continue;
            if (!hasOutput[name])
            {
                ti.packages ~= dependency;
                collectDependencies(dependency, ti);
                continue;
            }
            auto dependencyTarget = &targets[name];
            if (dependencyTarget.settings.targetType == TargetType.executable
                && ti.settings.targetType != TargetType.none)
                continue;
            ti.dependencies ~= name;
            ti.linkDependencies ~= name;
            collectDependencies(dependency, *dependencyTarget);
            const type = dependencyTarget.settings.targetType;
            if (type == TargetType.staticLibrary || type == TargetType.dynamicLibrary)
                ti.linkDependencies = ti.linkDependencies
                    .filter!(d => !dependencyTarget.linkDependencies.canFind(d)).array
                    ~ dependencyTarget.linkDependencies;
        }
        if (ti.settings.targetType == TargetType.none && ti.dependencies.length == 0)
            fail(text("`", p.name, "` has target type none and no dependencies to build"));
    }

    collectDependencies(root, *rootTarget);
    visited = null;

    // 1. Down: versions, debug versions, inherited options, ABI-critical dflags.
    void configureDependencies(ref const TargetInfo ti) @safe
    {
        foreach (name; ti.dependencies)
        {
            auto child = &targets[name];
            mergeFromDependent(ti, *child, request.inheritance);
            configureDependencies(*child);
        }
    }

    configureDependencies(*rootTarget);

    // 2. Across: `Have_` for each package incorporated and each direct dependency.
    foreach (ref ti; targets.byValue)
    {
        string[] names = ti.packages.map!(q => q.name).array ~ ti.dependencies;
        ti.settings.addVersions(names.map!haveVersion.array);
    }

    // 3. Up: the dependents receive their dependencies' settings.
    void configureDependents(ref TargetInfo ti) @safe
    {
        if (ti.package_ in visited)
            return;
        visited[ti.package_] = true;
        foreach (folded; ti.packages[1 .. $])
            ti.settings.add(targets[folded.name].settings);
        foreach (name; ti.dependencies)
        {
            auto dependencyTarget = &targets[name];
            configureDependents(*dependencyTarget);
            mergeFromDependency(dependencyTarget.settings, ti.settings, platform);
        }
    }

    configureDependents(*rootTarget);
    visited = null;

    // 4. Injected source files reach the final binaries.
    void injectInto(ref TargetInfo ti, ref TargetInfo binary) @safe
    {
        if (ti.package_ in visited)
            return;
        visited[ti.package_] = true;
        foreach (name; ti.dependencies)
        {
            auto dependencyTarget = &targets[name];
            if (dependencyTarget.settings.injectSourceFiles.length)
                binary.settings.addSourceFiles(dependencyTarget.settings.injectSourceFiles);
            injectInto(*dependencyTarget, binary);
        }
    }

    foreach (ref ti; targets.byValue)
        if (ti.settings.targetType == TargetType.executable
            || ti.settings.targetType == TargetType.dynamicLibrary)
        {
            injectInto(ti, ti);
            visited = null;
        }

    // 5. dub filters versions only under `--filter-versions`, which no
    // request uses; pruning (BGV1) is the variant keys' business.

    // 6. String import files of a dependent override a dependency's
    // same-named ones.
    void overrideStringImports(ref TargetInfo target, ref TargetInfo parent, string[] overrides) @safe
    {
        import std.path : baseName;

        if (target.settings.stringImportPaths.length == 0)
            return;
        bool anyOverride;
        foreach (ref f; target.settings.stringImportFiles)
            foreach (o; overrides)
                if (f != o && f.baseName == o.baseName)
                {
                    f = o;
                    anyOverride = true;
                }
        if (anyOverride)
            target.settings.prependStringImportPaths(parent.settings.stringImportPaths);
        overrides ~= target.settings.stringImportFiles;
        foreach (name; target.dependencies)
            overrideStringImports(targets[name], target, overrides);
    }

    foreach (name; rootTarget.dependencies)
        overrideStringImports(targets[name], *rootTarget, rootTarget.settings.stringImportFiles.dup);

    // 7. Dependency-specific settings (`dependency "x" { dflags … }`) are
    // outside the supported vocabulary: the recipe reader rejects them.

    foreach (name; targets.keys)
        if (!hasOutput[name])
            targets.remove(name);
}

// dub's `mergeFromDependent`, with the divergent mode's exception.
private void mergeFromDependent(ref const TargetInfo parent, ref TargetInfo child,
    VersionInheritance inheritance) @safe
{
    if (inheritance == VersionInheritance.faithful)
    {
        child.settings.addVersions(parent.settings.versions);
        child.settings.addDebugVersions(parent.settings.debugVersions);
    }
    else
    {
        // Only what the parent's configuration block alone does not add.
        child.settings.addVersions(parent.settings.versions
            .filter!(v => !parent.configurationVersions.canFind(v)).array);
        child.settings.addDebugVersions(parent.settings.debugVersions
            .filter!(v => !parent.configurationDebugVersions.canFind(v)).array);
    }
    child.settings.options |= parent.settings.options & inheritedBuildOptions;
    child.settings.addDFlags(abiCriticalFlags(parent.settings.dflags));
}

// dub's `mergeFromDependency`.
private void mergeFromDependency(const ref BuildSettings child, ref BuildSettings parent, const ref BuildPlatform platform)
    @safe
{
    parent.addDFlags(child.dflags);
    parent.addVersions(child.versions);
    parent.addDebugVersions(child.debugVersions);
    parent.addVersionFilters(child.versionFilters);
    parent.addDebugVersionFilters(child.debugVersionFilters);
    parent.addImportPaths(child.importPaths);
    parent.addCImportPaths(child.cImportPaths);
    parent.addStringImportPaths(child.stringImportPaths);
    parent.addInjectSourceFiles(child.injectSourceFiles);
    if (child.targetType == TargetType.staticLibrary || child.targetType == TargetType.dynamicLibrary)
    {
        parent.addSourceFiles(child.sourceFiles.filter!(f => isLinkerFile(platform, f)).array);
        parent.addLibs(child.libs);
        parent.addFrameworks(child.frameworks);
        parent.addLFlags(child.lflags);
    }
}

/// Whether `file` is something the linker takes: a library, object or
/// resource file (dub's `isLinkerFile`).
bool isLinkerFile(const BuildPlatform platform, string file) @safe pure nothrow
{
    switch (file.extension)
    {
    case ".lib", ".obj", ".res", ".def":
        return platform.isWindows;
    case ".a", ".o", ".so", ".dylib":
        return !platform.isWindows;
    default:
        return false;
    }
}

// dub's `ProjectGenerator.addBuildTypeSettings`: the root recipe's build type,
// without `unittests` below the root, then the actual compiler's options.
private void addBuildTypeSettings(Project project, ref TargetInfo ti, ref const ResolveRequest request,
    ref Variables variables) @safe
{
    import sparkles.build_primitives.resolve.settings : BuildRequirement;

    const isRoot = ti.package_ is project.root;
    if (!(ti.settings.requirements & BuildRequirement.noDefaultFlags))
    {
        BuildSettings buildType;
        addBuildType(project.root, buildType, request.platform, request.buildType, variables.driver,
            variables);
        if (!isRoot)
            buildType.options &= ~BuildOption.unittests;
        processVars(ti.settings, project.root, buildType, variables, false);
    }
    ti.settings.extractBuildOptions(request.platform.compiler);
    if (ti.settings.targetType == TargetType.sourceLibrary && isRoot
        && !(ti.settings.options & BuildOption.syntaxOnly))
        fail(text("the root package `", project.root.name, "` cannot have target type sourceLibrary"));
}

// dub's `Package.addBuildTypeSettings`: the recipe's own build type, else one
// of dub's built-in ones.
private void addBuildType(Package root, ref BuildSettings settings, const BuildPlatform platform,
    string buildType, ResolveDriver driver, ref Variables variables) @safe
{
    alias O = BuildOption;
    scope (success)
        settings.addDFlags(environmentDFlags(variables));
    if (auto custom = buildType in root.buildTypes)
    {
        applyTemplate(*custom, settings, platform, root.directory, driver);
        return;
    }
    switch (buildType)
    {
    case "$DFLAGS", "plain": break;
    case "debug": settings.options |= O.debugMode | O.debugInfo; break;
    case "release": settings.options |= O.releaseMode | O.optimize | O.inline; break;
    case "release-debug": settings.options |= O.releaseMode | O.optimize | O.inline | O.debugInfo; break;
    case "release-nobounds": settings.options |= O.releaseMode | O.optimize | O.inline | O.noBoundsCheck; break;
    case "unittest": settings.options |= O.unittests | O.debugMode | O.debugInfo; break;
    case "profile": settings.options |= O.profile | O.optimize | O.inline | O.debugInfo; break;
    case "profile-gc": settings.options |= O.profileGC | O.debugInfo; break;
    case "cov": settings.options |= O.coverage | O.debugInfo; break;
    case "cov-ctfe": settings.options |= O.coverageCTFE | O.debugInfo; break;
    case "unittest-cov": settings.options |= O.unittests | O.coverage | O.debugMode | O.debugInfo; break;
    case "unittest-cov-ctfe": settings.options |= O.unittests | O.coverageCTFE | O.debugMode | O.debugInfo; break;
    case "syntax": settings.options |= O.syntaxOnly; break;
    default:
        fail(text("unknown build type for `", root.name, "`: `", buildType, "`"));
    }
}

// The `DFLAGS` environment variable, split on white space, which dub adds to
// every build type last.
private string[] environmentDFlags(ref Variables variables) @safe
{
    import std.array : split;

    string dflags;
    if (!variables.driver.environment("DFLAGS", dflags))
        return null;
    variables.noteInput("DFLAGS");
    return dflags.split;
}

// What a variable reference in a value can see.
private struct Variables
{
    Project project;
    const(ResolveRequest)* request;
    ResolveDriver driver;
    const(string[string]) configurations;
    /// The environment variables the values referred to.
    string[] environmentInputs;

    void noteInput(string name) @safe pure nothrow
    {
        if (!environmentInputs.canFind(name))
            environmentInputs ~= name;
    }

    this(Project project, ref const ResolveRequest request, ResolveDriver driver,
        const string[string] configurations) @trusted
    {
        this.project = project;
        // Variables lives only as long as the resolution of `request`.
        this.request = &request;
        this.driver = driver;
        this.configurations = configurations;
    }

    // dub's `getVariable`.
    string value(string name, Package p, const string[string][] extra) @safe
    {
        import std.uni : toUpper;

        string path;
        if (name == "PACKAGE_DIR")
            path = p.directory;
        else if (name == "ROOT_PACKAGE_DIR")
            path = project.root.directory;
        if (name.endsWith("_PACKAGE_DIR"))
        {
            const wanted = name[0 .. $ - "_PACKAGE_DIR".length];
            foreach (q; project.topological)
                if (q.name.toUpper.replaceDash == wanted)
                {
                    path = q.directory;
                    break;
                }
        }
        if (path.length)
            return path;

        const platform = request.platform;
        switch (name)
        {
        case "DUB":
            return request.dubExecutable;
        case "ARCH":
            return platform.architecture.length ? platform.architecture[0] : "";
        case "PLATFORM":
            foreach (q; platform.platform)
                if (q != "posix")
                    return q;
            return platform.platform.length ? platform.platform[0] : "";
        case "PLATFORM_POSIX":
            if (platform.platform.canFind("posix"))
                return "posix";
            return platform.platform.length ? platform.platform[0] : "";
        case "BUILD_TYPE":
            return request.buildType;
        case "DFLAGS", "LFLAGS":
            // dub reads them in the request's configuration, whatever the package.
            const settings = p.buildSettings(platform, configurations.get(project.root.name, null), driver);
            return (name == "DFLAGS" ? settings.dflags : settings.lflags).join(" ");
        default:
            break;
        }
        foreach_reverse (aa; extra)
            if (auto found = name in aa)
                return *found;
        string environment;
        if (driver.environment(name, environment))
        {
            noteInput(name);
            return environment;
        }
        return fail(text("`", p.name, "`: invalid variable `$", name, "`"));
    }

    // dub's `expandVars`: `$NAME`, `${NAME}`, and `$$` for `$`.
    string expand(string s, Package p, const string[string][] extra) @safe
    {
        import std.ascii : isAlphaNum;
        import std.string : indexOf;

        string result;
        while (true)
        {
            auto at = s.indexOf('$');
            if (at < 0)
                return result ~ s;
            result ~= s[0 .. at];
            s = s[at + 1 .. $];
            if (s.length == 0)
                fail(text("`", p.name, "`: a variable name is expected after the `$` ending `",
                    result, "$`"));
            if (s[0] == '$')
            {
                result ~= "$";
                s = s[1 .. $];
            }
            else if (s[0] == '{')
            {
                const close = s.indexOf('}');
                if (close < 0)
                    fail(text("`", p.name, "`: no `}` closes `${`"));
                result ~= value(s[1 .. close], p, extra);
                s = s[close + 1 .. $];
            }
            else
            {
                size_t end;
                while (end < s.length && (isAlphaNum(s[end]) || s[end] == '_'))
                    ++end;
                result ~= value(s[0 .. end], p, extra);
                s = s[end .. $];
            }
        }
    }

    // A value, expanded, and for a path, made absolute against the package.
    string process(string s, Package p, bool isPath, const string[string][] extra) @safe
    {
        const expanded = expand(s, p, extra);
        if (!isPath)
            return expanded;
        return expanded.isAbsolute ? buildNormalizedPath(expanded)
            : buildNormalizedPath(p.directory, expanded);
    }

    string[] processAll(const string[] values, Package p, bool isPath, const string[string][] extra) @safe
    {
        string[] result;
        foreach (v; values)
            result ~= process(v, p, isPath, extra);
        return result;
    }
}

private string replaceDash(string s) @safe pure nothrow
{
    import std.array : replace;

    return s.replace("-", "_");
}

// dub's `processVars(ref BuildSettings dst, …)`.
private void processVars(ref BuildSettings dst, Package p, const ref BuildSettings settings,
    ref Variables variables, bool includeTargetSettings) @safe
{
    static void environmentInto(ref string[string] into, const string[string] values)
    {
        foreach (k, v; values)
            if (k !in into)
                into[k] = v;
    }

    string[string] environments, buildEnvironments, runEnvironments;
    foreach (k, v; settings.environments)
        environments[k] = variables.process(v, p, false, null);
    foreach (k, v; settings.buildEnvironments)
        buildEnvironments[k] = variables.process(v, p, false, null);
    foreach (k, v; settings.runEnvironments)
        runEnvironments[k] = variables.process(v, p, false, null);
    environmentInto(dst.environments, environments);
    environmentInto(dst.buildEnvironments, buildEnvironments);
    environmentInto(dst.runEnvironments, runEnvironments);

    const extra = [dst.environments, dst.buildEnvironments];
    dst.addDFlags(variables.processAll(settings.dflags, p, false, extra));
    dst.addLFlags(variables.processAll(settings.lflags, p, false, extra));
    dst.addLibs(variables.processAll(settings.libs, p, false, extra));
    dst.addFrameworks(variables.processAll(settings.frameworks, p, false, extra));
    dst.addSourceFiles(processFiles(settings.sourceFiles, p, variables, extra));
    dst.addImportFiles(variables.processAll(settings.importFiles, p, true, extra));
    dst.addStringImportFiles(variables.processAll(settings.stringImportFiles, p, true, extra));
    dst.addInjectSourceFiles(processFiles(settings.injectSourceFiles, p, variables, extra));
    dst.addCopyFiles(variables.processAll(settings.copyFiles, p, true, extra));
    dst.addExtraDependencyFiles(variables.processAll(settings.extraDependencyFiles, p, true, extra));
    dst.addVersions(variables.processAll(settings.versions, p, false, extra));
    dst.addDebugVersions(variables.processAll(settings.debugVersions, p, false, extra));
    dst.addVersionFilters(variables.processAll(settings.versionFilters, p, false, extra));
    dst.addDebugVersionFilters(variables.processAll(settings.debugVersionFilters, p, false, extra));
    dst.addImportPaths(variables.processAll(settings.importPaths, p, true, extra));
    dst.addCImportPaths(variables.processAll(settings.cImportPaths, p, true, extra));
    dst.addStringImportPaths(variables.processAll(settings.stringImportPaths, p, true, extra));
    dst.requirements |= settings.requirements;
    dst.options |= settings.options;
    // Commands keep their variables: they expand when a generator runs (D8).
    dst.addPreGenerateCommands(settings.preGenerateCommands);
    dst.addPostGenerateCommands(settings.postGenerateCommands);
    dst.addPreBuildCommands(settings.preBuildCommands);
    dst.addPostBuildCommands(settings.postBuildCommands);
    dst.addPreRunCommands(settings.preRunCommands);
    dst.addPostRunCommands(settings.postRunCommands);

    if (includeTargetSettings)
    {
        dst.targetType = settings.targetType;
        dst.targetPath = variables.process(settings.targetPath, p, true, extra);
        dst.targetName = settings.targetName;
        if (settings.workingDirectory.length)
            dst.workingDirectory = variables.process(settings.workingDirectory, p, true, extra);
        if (settings.mainSourceFile.length)
            dst.mainSourceFile = variables.process(settings.mainSourceFile, p, true, extra);
    }
}

// Source files: dub expands a glob in one against the tool's working
// directory, which no recipe in scope relies on; a glob is an error.
private string[] processFiles(const string[] files, Package p, ref Variables variables,
    const string[string][] extra) @safe
{
    string[] result;
    foreach (f; files)
    {
        const processed = variables.process(f, p, true, extra);
        if (processed.canFind!(c => c == '*' || c == '?' || c == '[' || c == '{'))
            fail(text("`", p.name, "`: a glob in a source file list (`", f, "`) is not supported"));
        result ~= processed;
    }
    return result;
}

version (unittest)
{
    import sparkles.build_primitives.resolve.driver : MemoryDriver;

    private enum linuxLdc = BuildPlatform(["linux", "posix"], ["x86_64"], "ldc", "ldc2", 2111, "1.41.0");

    // A repository of four packages: `app` uses `lib` and the source
    // library `util`; `lib` uses `util` and `leaf`, selecting `leaf`'s
    // `special` configuration.
    private MemoryDriver fixture() @safe
    {
        return new MemoryDriver([
            "/r/dub.sdl": `name "r"
subPackage "app"
subPackage "lib"
subPackage "util"
subPackage "leaf"
`,
            "/r/app/dub.sdl": `name "app"
targetType "executable"
dependency "r:lib" path=".."
dependency "r:util" path=".."
configuration "default" {
    versions "AppOnly"
    dflags "-mcpu=native" "-preview=in"
}
configuration "unittest" {
    dflags "-checkaction=context"
}
buildType "fast" {
    buildOptions "optimize" "inline"
    dflags "-O3" platform="ldc"
}
`,
            "/r/app/source/app.d": "void main() {}",
            "/r/app/source/other.d": "",
            "/r/lib/dub.sdl": `name "lib"
dependency "r:util" path=".."
dependency "r:leaf" path=".."
subConfiguration "r:leaf" "special"
dflags "-lib-flag" platform="linux-ldc"
dflags "-win-flag" platform="windows"
`,
            "/r/lib/src/lib.d": "",
            "/r/util/dub.sdl": `name "util"
targetType "sourceLibrary"
versions "UtilVersion"
`,
            "/r/util/source/util.d": "",
            "/r/leaf/dub.sdl": `name "leaf"
configuration "plain" {
}
configuration "special" {
    versions "Special"
}
importPaths "include"
`,
            "/r/leaf/source/leaf.d": "",
        ]);
    }

    private Resolution resolved(ResolveRequest request) @safe
    {
        auto result = resolve(request, fixture);
        assert(result.hasValue, result.hasError ? result.error.message : null);
        return result.value;
    }
}

@("build_primitives.resolve.configure.resolve.sourceLibraryFoldedIntoEachConsumer")
@safe unittest
{
    const r = resolved(ResolveRequest(directory: "/r", subPackage: ":app", platform: linuxLdc));
    assert(r.rootPackage == "r:app" && r.configuration == "default");
    // `util` builds nothing of its own: it is folded into both its consumers.
    assert(r.target("r:util") is null);
    const app = r.target("r:app");
    const lib = r.target("r:lib");
    assert(app.packages == ["r:app", "r:util"] && lib.packages == ["r:lib", "r:util"]);
    assert(app.settings.sourceFiles.canFind("/r/util/source/util.d"));
    assert(lib.settings.sourceFiles.canFind("/r/util/source/util.d"));
    assert(app.linkDependencies == ["r:lib", "r:leaf"] && app.dependencies == ["r:lib"]);
    assert(r.targets[0].package_ == "r:app");
}

@("build_primitives.resolve.configure.resolve.subConfigurationTwoLevelsDown")
@safe unittest
{
    const r = resolved(ResolveRequest(directory: "/r", subPackage: ":app", platform: linuxLdc));
    assert(r.configurations["r:leaf"] == "special");
    assert(r.target("r:leaf").settings.versions.canFind("Special"));
    // Up: the dependency's versions and import paths reach every dependent.
    assert(r.target("r:app").settings.versions.canFind("Special"));
    assert(r.target("r:app").settings.importPaths.canFind("/r/leaf/include"));
}

@("build_primitives.resolve.configure.resolve.downAcrossUp")
@safe unittest
{
    const r = resolved(ResolveRequest(directory: "/r", subPackage: ":app", platform: linuxLdc));
    const leaf = r.target("r:leaf").settings;
    // Down: the root's versions and its ABI-critical dflags, not the others.
    assert(leaf.versions.canFind("AppOnly"));
    assert(leaf.dflags.canFind("-mcpu=native") && !leaf.dflags.canFind("-preview=in"));
    // Across and up: `Have_` versions.
    assert(r.target("r:lib").settings.versions.canFind("Have_r_leaf"));
    assert(r.target("r:app").settings.versions.canFind("Have_r_leaf"));
    assert(r.target("r:app").settings.versions.canFind("Have_r_util"));
    // A platform-qualified setting applies on its platform only.
    assert(r.target("r:lib").settings.dflags.canFind("-lib-flag"));
    assert(!r.target("r:app").settings.dflags.canFind("-win-flag"));
    // The default `debug` build type, with its options passed down.
    assert(leaf.options & BuildOption.debugMode);
    assert(r.target("r:lib").settings.targetType == TargetType.staticLibrary);
}

@("build_primitives.resolve.configure.resolve.buildTypeOfTheRootOnly")
@safe unittest
{
    const r = resolved(ResolveRequest(directory: "/r", subPackage: ":app", buildType: "fast",
        platform: linuxLdc));
    // The root's build type applies to every target; `-O3` is LDC's spelling
    // of `optimize`, so it becomes the option.
    foreach (ref t; r.targets)
    {
        assert(t.settings.options & BuildOption.optimize, t.package_);
        assert(!t.settings.dflags.canFind("-O3"), t.package_);
    }
    auto unknown = resolve(ResolveRequest(directory: "/r", subPackage: ":lib", buildType: "fast",
        platform: linuxLdc), fixture);
    assert(unknown.hasError && unknown.error.message == "unknown build type for `r:lib`: `fast`");
}

@("build_primitives.resolve.configure.resolve.divergentInheritance")
@safe unittest
{
    const r = resolved(ResolveRequest(directory: "/r", subPackage: ":app", platform: linuxLdc,
        inheritance: VersionInheritance.divergent));
    const leaf = r.target("r:leaf").settings;
    assert(!leaf.versions.canFind("AppOnly"));
    assert(leaf.dflags.canFind("-mcpu=native"));
}

@("build_primitives.resolve.configure.resolve.testRoot")
@safe unittest
{
    const r = resolved(ResolveRequest(directory: "/r", subPackage: ":lib", buildType: "unittest",
        platform: linuxLdc, testRoot: true));
    assert(r.configuration == "r-lib-test-library" && r.testRoot.generated);
    assert(r.testRoot.testedSources == ["src/lib.d"]);
    const lib = r.target("r:lib");
    assert(lib.settings.targetType == TargetType.executable && lib.settings.targetName == "r-lib-test-library");
    assert(lib.settings.options & BuildOption.unittests);
    assert(!(r.target("r:leaf").settings.options & BuildOption.unittests));

    // A configuration's target type replaces the top level's even when it
    // states none, so `app`'s `unittest` is no executable: as dub does, the
    // generated configuration copies it. No main file is stated, so none is left out.
    const app = resolved(ResolveRequest(directory: "/r", subPackage: ":app", buildType: "unittest",
        platform: linuxLdc, testRoot: true));
    assert(app.configuration == "r-app-test-unittest" && app.testRoot.generated);
    assert(app.testRoot.testedSources == ["source/app.d", "source/other.d"]);
    assert(app.target("r:app").settings.dflags.canFind("-checkaction=context"));
}

@("build_primitives.resolve.configure.resolve.errors")
@safe unittest
{
    auto missing = resolve(ResolveRequest(directory: "/r", subPackage: ":nope", platform: linuxLdc), fixture);
    assert(missing.hasError && missing.error.message.canFind("no subpackage `nope`"), missing.error.message);
    auto noConfiguration = resolve(ResolveRequest(directory: "/r", subPackage: ":leaf",
        configuration: "absent", platform: linuxLdc), fixture);
    assert(noConfiguration.hasError);
    auto driver = fixture;
    driver.files["/r/lib/dub.sdl"] = "name \"lib\"\ndependency \"absent\" version=\"~>1.0\"\n";
    auto unlocked = resolve(ResolveRequest(directory: "/r", subPackage: ":lib", platform: linuxLdc), driver);
    assert(unlocked.hasError && unlocked.error.message.canFind("in neither DUB lock"), unlocked.error.message);
}

@("build_primitives.resolve.configure.resolve.variables")
@safe unittest
{
    auto driver = new MemoryDriver([
        "/v/dub.sdl": `name "v"
importPaths "$PACKAGE_DIR/gen" "${ROOT_PACKAGE_DIR}/x"
dflags "-a=$ARCH-$PLATFORM-$PLATFORM_POSIX-$BUILD_TYPE" "-b=$$HOME" "-c=$SDK"
`,
        "/v/source/v.d": "",
    ], ["SDK": "21"]);
    auto r = resolve(ResolveRequest(directory: "/v", platform: linuxLdc), driver);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    const v = r.value.targets[0].settings;
    // Stated import paths replace the default `source/` one.
    assert(v.importPaths == ["/v/gen", "/v/x"], text(v.importPaths));
    assert(v.dflags == ["-a=x86_64-linux-posix-debug", "-b=$HOME", "-c=21"], text(v.dflags));
    assert(r.value.environmentInputs == ["SDK"]);
    driver.files["/v/dub.sdl"] = "name \"v\"\ndflags \"$NOPE\"\n";
    assert(resolve(ResolveRequest(directory: "/v", platform: linuxLdc), driver).hasError);
}

@("build_primitives.resolve.configure.resolve.singleFilePackage")
@safe unittest
{
    auto driver = fixture;
    driver.files["/r/examples/demo.d"] = "#!/usr/bin/env dub\n/+ dub.sdl:\n    dependency \"r:lib\" version=\"*\"\n+/\nvoid main() {}\n";
    driver.files["/r/examples/helper.d"] = "";

    auto r = resolve(ResolveRequest(singleFile: "/r/examples/demo.d", platform: linuxLdc,
        inTree: ["r": "/r"]), driver);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    // Named after the file; its only source is the file itself.
    const demo = r.value.targets[0];
    assert(demo.package_ == "demo" && demo.settings.targetType == TargetType.executable);
    assert(demo.settings.sourceFiles == ["/r/examples/demo.d"]);
    assert(demo.dependencies == ["r:lib"]);

    // Without the rewrite, a dependency by version must be in a lock.
    assert(resolve(ResolveRequest(singleFile: "/r/examples/demo.d", platform: linuxLdc), driver).hasError);
    driver.files["/r/examples/bad.d"] = "/+ dub.sdl:\n    sourcePaths \".\"\n+/\n";
    assert(resolve(ResolveRequest(singleFile: "/r/examples/bad.d", platform: linuxLdc), driver).hasError);
}

@("build_primitives.resolve.configure.resolve.stringImportsAndTargetKinds")
@safe unittest
{
    auto driver = new MemoryDriver([
        "/s/dub.sdl": "name \"s\"\nsubPackage \"top\"\nsubPackage \"dep\"\nsubPackage \"dyn\"\n",
        "/s/top/dub.sdl": `name "top"
targetType "executable"
dependency "s:dep" path=".."
dependency "s:dyn" path=".."
stringImportPaths "views"
injectSourceFiles "inject.d"
`,
        "/s/top/source/app.d": "",
        "/s/top/views/data.txt": "",
        "/s/dep/dub.sdl": `name "dep"
stringImportPaths "views"
mainSourceFile "source/main.d"
injectSourceFiles "source/injected.d"
lflags "-ldep"
`,
        "/s/dep/source/dep.d": "",
        "/s/dep/source/main.d": "",
        "/s/dep/source/injected.d": "",
        "/s/dep/views/data.txt": "",
        "/s/dep/views/own.txt": "",
        "/s/dyn/dub.sdl": "name \"dyn\"\ntargetType \"dynamicLibrary\"\nbuildRequirements \"noDefaultFlags\"\n",
        "/s/dyn/source/dyn.d": "",
    ]);
    auto r = resolve(ResolveRequest(directory: "/s", subPackage: ":top", platform: linuxLdc), driver);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    const top = r.value.target("s:top").settings;
    const dep = r.value.target("s:dep").settings;
    const dyn = r.value.target("s:dyn").settings;
    // Step 6: the dependent's `data.txt` overrides the dependency's.
    assert(dep.stringImportFiles.canFind("/s/top/views/data.txt"), text(dep.stringImportFiles));
    assert(dep.stringImportPaths[0] == "/s/top/views");
    // A library's main file moves to the root executable, which also
    // receives the injected files and the static library's lflags.
    assert(!dep.sourceFiles.canFind("/s/dep/source/main.d"));
    assert(top.sourceFiles.canFind("/s/dep/source/main.d"));
    assert(top.sourceFiles.canFind("/s/dep/source/injected.d"));
    assert(top.lflags.canFind("-ldep"));
    // A dynamic library is position independent; `noDefaultFlags` keeps
    // the build type off it.
    assert(dyn.options & BuildOption.pic);
    assert(!(dyn.options & BuildOption.debugMode) && top.options & BuildOption.debugMode);
}

@("build_primitives.resolve.configure.resolve.registryAndToolchain")
@safe unittest
{
    import sparkles.build_primitives.resolve.project : RegistrySource;

    auto driver = new MemoryDriver([
        "/a/dub.sdl": `name "a"
dependency "lib" version="~>1.2"
toolchainRequirements frontend=">=2.100" ldc=">=1.40"
importPaths "$LIB_PACKAGE_DIR/extra"
`,
        "/a/source/a.d": "",
        "/store/lib/dub.json": `{"name": "lib", "version": "1.2.7", "importPaths": ["src"], "sourcePaths": ["src"]}`,
        "/store/lib/src/lib.d": "",
    ]);
    auto request = ResolveRequest(directory: "/a", platform: linuxLdc);
    request.registry["lib"] = RegistrySource("/store/lib", "1.2.7");
    auto r = resolve(request, driver);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    assert(r.value.target("lib").settings.sourceFiles == ["/store/lib/src/lib.d"]);
    assert(r.value.target("a").settings.importPaths.canFind("/store/lib/extra"));

    // The locks pin a version the recipe does not admit.
    request.registry["lib"] = RegistrySource("/store/lib", "2.0.0");
    auto mismatch = resolve(request, driver);
    assert(mismatch.hasError && mismatch.error.message.canFind("the locks pin 2.0.0"), mismatch.error.message);

    // A compiler older than the recipe admits.
    request.registry["lib"] = RegistrySource("/store/lib", "1.2.7");
    request.platform.compilerVersion = "1.39.0";
    auto old = resolve(request, driver);
    assert(old.hasError && old.error.message.canFind("requires ldc >=1.40"), old.error.message);

    // A relative path is refused, not resolved against the working directory.
    auto relative = resolve(ResolveRequest(directory: "a", platform: linuxLdc), driver);
    assert(relative.hasError);

    // A registry package pinned at a commit depends on its own subpackage
    // with a range the commit cannot satisfy: it is the same package.
    auto own = new MemoryDriver([
        "/a/dub.sdl": "name \"a\"\ndependency \"dmd\" repository=\"git+https://x/dmd.git\" version=\"0123abc\"\n",
        "/a/source/a.d": "",
        "/store/dmd/dub.sdl": "name \"dmd\"\ndependency \"dmd:parser\" version=\"*\"\n"
            ~ "subPackage {\n    name \"parser\"\n    sourcePaths \"parser\"\n}\n",
        "/store/dmd/source/dmd.d": "",
        "/store/dmd/parser/p.d": "",
    ]);
    auto pinned = ResolveRequest(directory: "/a", platform: linuxLdc);
    pinned.registry["dmd"] = RegistrySource("/store/dmd", "0123abc", "git+https://x/dmd.git");
    auto commit = resolve(pinned, own);
    assert(commit.hasValue, commit.hasError ? commit.error.message : null);
    assert(commit.value.target("dmd:parser").settings.sourceFiles == ["/store/dmd/parser/p.d"]);
}

@("build_primitives.resolve.configure.resolve.hiddenEdgesAndEnvironment")
@safe unittest
{
    // Oracle 13: a reach into another package with no dependency on it is
    // reported, with its recipe line.
    auto driver = fixture;
    driver.files["/r/leaf/dub.sdl"] = "name \"leaf\"\nimportPaths \"../util/source\"\n";
    driver.variables["DFLAGS"] = "-extra";
    auto r = resolve(ResolveRequest(directory: "/r", subPackage: ":leaf", platform: linuxLdc), driver);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    assert(r.value.hiddenEdges.length == 1, text(r.value.hiddenEdges));
    assert(r.value.hiddenEdges[0].reached == "r:util" && r.value.hiddenEdges[0].line == 2);
    // dub adds `$DFLAGS` to every build type; it is an input.
    assert(r.value.targets[0].settings.dflags.canFind("-extra"));
    assert(r.value.environmentInputs == ["DFLAGS"]);
}
