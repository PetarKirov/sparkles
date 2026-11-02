/**
A recipe's build settings in the form resolution works on: each list setting
grouped by platform specifier, as dub's `BuildSettingsTemplate` groups it, and
applied to one platform as dub's `getPlatformSettings` applies it
(build-graph SPEC BGR2).

The groups are D associative arrays keyed by the specifier, filled in recipe
order, because dub's are: the order in which differently-qualified
occurrences of one setting are applied is dub's associative-array order, and
reproducing it is what makes the ordered fields agree.

Copied from dub (`BuildSettingsTemplate`, `getPlatformSettings`,
`Package.fillWithDefaults`); see the build-graph decisions on behaviour
copied from dub's source.
*/
module sparkles.build_primitives.resolve.recipe;

import std.algorithm.searching : canFind, startsWith;
import std.conv : text;

import sparkles.build_primitives.dub_manifest : DubDependency, DubPlatformValues;
import sparkles.build_primitives.resolve.driver : ResolveDriver;
import sparkles.build_primitives.resolve.platform : BuildPlatform, matchesSpecification;
import sparkles.build_primitives.resolve.settings : BuildSettings, TargetType, buildOptionNamed,
    buildRequirementNamed, extractBuildOptions, parseTargetType;

/// A dependency as a recipe states it.
struct DependencySpec
{
    string version_;    ///
    string path;        ///
    string repository;  ///
    bool optional;      ///
    bool default_;      ///
}

/// The list settings a template groups by platform, in dub's application order.
enum string[] listSettings = [
    "dflags", "lflags", "libs", "frameworks", "sourceFiles", "excludedSourceFiles",
    "injectSourceFiles", "copyFiles", "extraDependencyFiles", "versions", "debugVersions",
    "versionFilters", "debugVersionFilters", "importPaths", "cImportPaths", "stringImportPaths",
    "preGenerateCommands", "postGenerateCommands", "preBuildCommands", "postBuildCommands",
    "preRunCommands", "postRunCommands",
];

/// One declaration's settings: the top level of a recipe, a configuration or
/// a build type.
struct SettingsTemplate
{
    DependencySpec[string] dependencies; ///
    string[string] subConfigurations;    ///
    TargetType targetType;               ///
    string targetPath;                   ///
    string targetName;                   ///
    string workingDirectory;             ///
    string mainSourceFile;               ///

    string[][string] dflags;               ///
    string[][string] lflags;               ///
    string[][string] libs;                 ///
    string[][string] frameworks;           ///
    string[][string] sourceFiles;          ///
    string[][string] sourcePaths;          ///
    string[][string] cSourcePaths;         ///
    string[][string] excludedSourceFiles;  ///
    string[][string] injectSourceFiles;    ///
    string[][string] copyFiles;            ///
    string[][string] extraDependencyFiles; ///
    string[][string] versions;             ///
    string[][string] debugVersions;        ///
    string[][string] versionFilters;       ///
    string[][string] debugVersionFilters;  ///
    string[][string] importPaths;          ///
    string[][string] cImportPaths;         ///
    string[][string] stringImportPaths;    ///
    string[][string] preGenerateCommands;  ///
    string[][string] postGenerateCommands; ///
    string[][string] preBuildCommands;     ///
    string[][string] postBuildCommands;    ///
    string[][string] preRunCommands;       ///
    string[][string] postRunCommands;      ///
    string[string][string] environments;      ///
    string[string][string] buildEnvironments; ///
    string[string][string] runEnvironments;   ///
    uint[string] buildRequirements; ///
    uint[string] buildOptions;      ///
}

/// A template's configuration: its name, its platform restriction, its settings.
struct ConfigurationTemplate
{
    string name;           ///
    string[] platforms;    ///
    SettingsTemplate settings; ///
    /// The configuration this one copies, for the one `dub test` generates;
    /// null for one a recipe states.
    string copiedFrom;

    /// Whether the configuration applies on `platform`.
    bool matchesPlatform(const BuildPlatform platform) const @safe pure nothrow @nogc
    {
        if (platforms.length == 0)
            return true;
        foreach (p; platforms)
            if (platform.matchesSpecification(p))
                return true;
        return false;
    }
}

/// Why a recipe cannot be turned into templates.
struct RecipeError
{
    string recipe;  /// the recipe file
    string message; ///
}

/**
The template of one declaration of a recipe (`declaration` mixes in
`DubBuildSettingFields`), qualifying `:name` dependencies with
`packageName`'s root. Returns false with `error` set on a value dub rejects.
*/
bool toTemplate(D)(const ref D declaration, string packageName, out SettingsTemplate result,
    out string error) @safe
{
    foreach (ref dependency; declaration.dependencies)
    {
        const name = expandPackageName(dependency.name, packageName);
        if (name in result.dependencies)
        {
            error = text("the dependency `", name, "` is specified more than once");
            return false;
        }
        if (dependency.path.length == 0 && dependency.repository.length == 0
            && dependency.version_.length == 0)
        {
            error = text("the dependency `", name, "` names no version, path or repository");
            return false;
        }
        result.dependencies[name] = DependencySpec(dependency.version_, dependency.path,
            dependency.repository, dependency.optional, dependency.default_);
    }
    foreach (ref s; declaration.subConfigurations)
        result.subConfigurations[expandPackageName(s.dependency, packageName)] = s.configuration;

    if (!parseTargetType(declaration.targetType, result.targetType))
    {
        error = text("unknown target type `", declaration.targetType, "`");
        return false;
    }
    result.targetPath = declaration.targetPath;
    result.targetName = declaration.targetName;
    result.workingDirectory = declaration.workingDirectory;
    result.mainSourceFile = declaration.mainSourceFile;

    static foreach (name; listSettings ~ ["sourcePaths", "cSourcePaths"])
        group(__traits(getMember, declaration, name), __traits(getMember, result, name));
    static foreach (name; ["environments", "buildEnvironments", "runEnvironments"])
        foreach (ref entry; __traits(getMember, declaration, name))
        {
            if (entry.values.length != 2)
            {
                error = text("`", name, "` takes a name and a value");
                return false;
            }
            __traits(getMember, result, name)[entry.platform][entry.values[0]] = entry.values[1];
        }
    foreach (ref entry; declaration.buildOptions)
    {
        auto bits = &result.buildOptions.require(entry.platform, 0u);
        foreach (value; entry.values)
        {
            const option = buildOptionNamed(value);
            if (option == 0)
            {
                error = text("unknown build option `", value, "`");
                return false;
            }
            *bits |= option;
        }
    }
    foreach (ref entry; declaration.buildRequirements)
    {
        auto bits = &result.buildRequirements.require(entry.platform, 0u);
        foreach (value; entry.values)
        {
            const requirement = buildRequirementNamed(value);
            if (requirement == 0)
            {
                error = text("unknown build requirement `", value, "`");
                return false;
            }
            *bits |= requirement;
        }
    }
    return true;
}

// Appends each occurrence's values to its platform's group, creating the
// group even for an occurrence without values (`sourcePaths` alone).
private void group(const DubPlatformValues[] entries, ref string[][string] into) @safe pure
{
    foreach (ref entry; entries)
        into.require(entry.platform, null) ~= entry.values;
}

/// `:sub` qualified with the root of `packageName`; any other name as written.
string expandPackageName(string name, string packageName) @safe pure nothrow
{
    import std.string : indexOf;

    if (!name.startsWith(":"))
        return name;
    const colon = packageName.indexOf(':');
    return (colon < 0 ? packageName : packageName[0 .. colon]) ~ name;
}

/**
Fills in what dub assumes when a recipe is silent (`Package.fillWithDefaults`):
`views` as the string import path, `source/` or `src/` as the source and
import path, and the `application` and `library` configurations of a recipe
that declares none, `app.d` or `main.d` choosing the application's main file.
*/
void fillWithDefaults(ref SettingsTemplate top, ref ConfigurationTemplate[] configurations,
    string packageName, string directory, ResolveDriver driver) @safe
{
    import std.path : buildPath;

    if ("" !in top.stringImportPaths && driver.exists(directory.buildPath("views")))
        top.stringImportPaths.require("", null) ~= "views";

    const hasSourcePaths = ("" in top.sourcePaths) !is null;
    const hasImportPaths = ("" in top.importPaths) !is null;
    if (!hasSourcePaths || !hasImportPaths)
        foreach (defaultPath; ["source/", "src/"])
            if (driver.exists(directory.buildPath(defaultPath)))
            {
                if (!hasSourcePaths)
                    top.sourcePaths.require("", null) ~= defaultPath;
                if (!hasImportPaths)
                    top.importPaths.require("", null) ~= defaultPath;
            }

    if (configurations.length)
        return;
    string mainFile;
    const name = packageName.length ? packageName : "unknown";
    search: foreach_reverse (sourcePath; top.sourcePaths.get("", null))
    {
        if (!driver.exists(directory.buildPath(sourcePath)))
            continue;
        foreach (candidate; ["app.d", "main.d", name ~ "/main.d", name ~ "/app.d"])
            if (driver.exists(directory.buildPath(sourcePath, candidate)))
            {
                mainFile = joinRelative(sourcePath, candidate);
                break search;
            }
    }

    if (top.targetType == TargetType.executable)
    {
        SettingsTemplate application;
        application.targetType = TargetType.executable;
        if (top.mainSourceFile.length == 0)
            application.mainSourceFile = mainFile;
        configurations ~= ConfigurationTemplate("application", null, application);
    }
    else if (top.targetType != TargetType.none)
    {
        SettingsTemplate library;
        library.targetType = top.targetType == TargetType.autodetect ? TargetType.library : top.targetType;
        if (top.targetType == TargetType.autodetect && mainFile.length)
        {
            library.excludedSourceFiles.require("", null) ~= mainFile;
            SettingsTemplate application;
            application.targetType = TargetType.executable;
            application.mainSourceFile = mainFile;
            configurations ~= ConfigurationTemplate("application", null, application);
        }
        configurations ~= ConfigurationTemplate("library", null, library);
    }
}

// `a/` ~ `b`, as dub's `NativePath(a) ~ b` prints it.
private string joinRelative(string directory, string file) @safe pure nothrow
{
    import std.path : buildNormalizedPath;

    return buildNormalizedPath(directory, file);
}

/**
Applies `template_` to `platform` on top of `into`, for the package in
`directory`, as dub's `getPlatformSettings`: the singular settings replace,
the source paths are listed into source and import files (`.d` files, and
`.c`/`.i` files under C source paths, hidden files skipped), and each list
setting adds the groups whose specifier matches, in group order. File paths
are relative to `directory`, as dub's are at this stage.
*/
void applyTemplate(const SettingsTemplate template_, ref BuildSettings into, const BuildPlatform platform,
    string directory, ResolveDriver driver) @safe
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.path : buildNormalizedPath;

    into.targetType = template_.targetType;
    if (template_.targetPath.length)
        into.targetPath = template_.targetPath;
    if (template_.targetName.length)
        into.targetName = template_.targetName;
    if (template_.workingDirectory.length)
        into.workingDirectory = template_.workingDirectory;
    if (template_.mainSourceFile.length)
    {
        into.mainSourceFile = buildNormalizedPath(template_.mainSourceFile);
        into.addSourceFiles(into.mainSourceFile);
    }

    into.addSourceFiles(collectFiles(template_.sourcePaths, ["*.d"], platform, directory, driver));
    into.addSourceFiles(collectFiles(template_.cSourcePaths, ["*.c", "*.i"], platform, directory, driver));
    into.sourceFiles.sort;

    auto importFiles = (collectFiles(template_.importPaths, ["*.d", "*.di"], platform, directory, driver)
        ~ collectFiles(template_.cImportPaths, ["*.h"], platform, directory, driver)).sort.release;
    string[] onlyImported;
    foreach (file; importFiles)
        if (!into.sourceFiles.canFind(file))
            onlyImported ~= file;
    into.addImportFiles(onlyImported);
    into.addStringImportFiles(collectFiles(template_.stringImportPaths, ["*"], platform, directory, driver));

    void each(string name)(void delegate(string[]) @safe add)
    {
        foreach (specifier, values; __traits(getMember, template_, name))
            if (platform.matchesSpecification(specifier))
                add(values.dup);
    }

    each!"dflags"(v => into.addDFlags(v));
    each!"lflags"(v => into.addLFlags(v));
    each!"libs"(v => into.addLibs(v));
    each!"frameworks"(v => into.addFrameworks(v));
    each!"sourceFiles"(v => into.addSourceFiles(v));
    each!"excludedSourceFiles"(v => into.removeSourceFiles(v));
    each!"injectSourceFiles"(v => into.addInjectSourceFiles(v));
    each!"copyFiles"(v => into.addCopyFiles(v));
    each!"extraDependencyFiles"(v => into.addExtraDependencyFiles(v));
    each!"versions"(v => into.addVersions(v));
    each!"debugVersions"(v => into.addDebugVersions(v));
    each!"versionFilters"(v => into.addVersionFilters(v));
    each!"debugVersionFilters"(v => into.addDebugVersionFilters(v));
    each!"importPaths"(v => into.addImportPaths(v));
    each!"cImportPaths"(v => into.addCImportPaths(v));
    each!"stringImportPaths"(v => into.addStringImportPaths(v));
    each!"preGenerateCommands"(v => into.addPreGenerateCommands(v));
    each!"postGenerateCommands"(v => into.addPostGenerateCommands(v));
    each!"preBuildCommands"(v => into.addPreBuildCommands(v));
    each!"postBuildCommands"(v => into.addPostBuildCommands(v));
    each!"preRunCommands"(v => into.addPreRunCommands(v));
    each!"postRunCommands"(v => into.addPostRunCommands(v));
    static foreach (name; ["environments", "buildEnvironments", "runEnvironments"])
        foreach (specifier, values; __traits(getMember, template_, name))
            if (platform.matchesSpecification(specifier))
                foreach (key, value; values)
                    if (key !in __traits(getMember, into, name))
                        __traits(getMember, into, name)[key] = value;
    foreach (specifier, bits; template_.buildRequirements)
        if (platform.matchesSpecification(specifier))
            into.requirements |= bits;
    foreach (specifier, bits; template_.buildOptions)
        if (platform.matchesSpecification(specifier))
            into.options |= bits;
}

// dub's `collectFiles`: the files under each matching path whose base name
// matches one of `patterns`, relative to `directory`. A path that is no
// directory is skipped; dub warns about it unless it names a variable.
private string[] collectFiles(const string[][string] paths, const string[] patterns,
    const BuildPlatform platform, string directory, ResolveDriver driver) @safe
{
    import std.algorithm.searching : any;
    import std.path : absolutePath, baseName, buildNormalizedPath, globMatch, isAbsolute,
        pathSplitter, relativePath;

    string[] files;
    foreach (specifier, list; paths)
    {
        if (!platform.matchesSpecification(specifier))
            continue;
        foreach (path; list)
        {
            if (path.length == 0)
            {
                import sparkles.build_primitives.resolve.project : fail;

                fail(text(directory, ": a source or import path must not be empty"));
            }
            const root = buildNormalizedPath(path.isAbsolute ? path : buildNormalizedPath(directory, path));
            if (!driver.isDirectory(root))
                continue;
            foreach (file; driver.filesBelow(root))
            {
                if (pathSplitter(file[root.length .. $]).any!(part => part.length && part[0] == '.'))
                    continue;
                if (!patterns.any!(p => globMatch(file.baseName, p)))
                    continue;
                files ~= relativePath(file, directory);
            }
        }
    }
    return files;
}

/// The settings of one package for one configuration and platform, as dub's
/// `Package.getBuildSettings`: the top level, then the configuration, the
/// default target name, and the dflags DMD spells as options.
BuildSettings packageSettings(const SettingsTemplate top, const ConfigurationTemplate[] configurations,
    string configuration, string packageName, const BuildPlatform platform, string directory,
    ResolveDriver driver) @safe
{
    import std.array : replace;

    BuildSettings settings;
    applyTemplate(top, settings, platform, directory, driver);
    foreach (ref c; configurations)
        if (c.name == configuration)
        {
            applyTemplate(c.settings, settings, platform, directory, driver);
            break;
        }
    if (settings.targetName.length == 0)
        settings.targetName = packageName.replace(":", "_");
    settings.extractBuildOptions("dmd");
    return settings;
}

@("build_primitives.resolve.recipe.toTemplate.groupsByPlatform")
@safe unittest
{
    import sparkles.build_primitives.dub_manifest : parseDubManifest;

    const manifest = parseDubManifest(`name "p"
dflags "-a"
dflags "-b" platform="ldc"
dflags "-c"
sourcePaths
dependency ":sub" path="sub"
buildOptions "betterC" platform="posix"
environments "K" "V"
`).value;
    SettingsTemplate t;
    string error;
    assert(toTemplate(manifest, "p", t, error), error);
    assert(t.dflags[""] == ["-a", "-c"] && t.dflags["ldc"] == ["-b"]);
    assert("" in t.sourcePaths && t.sourcePaths[""].length == 0);
    assert(t.dependencies["p:sub"].path == "sub");
    assert(t.buildOptions["posix"] != 0 && t.environments[""]["K"] == "V");

    const bad = parseDubManifest("name \"p\"\nbuildOptions \"fast\"\n").value;
    assert(!toTemplate(bad, "p", t, error) && error == "unknown build option `fast`");
    const twice = parseDubManifest("name \"p\"\ndependency \"q\" version=\"*\"\ndependency \"q\" path=\"q\"\n").value;
    assert(!toTemplate(twice, "p", t, error));
}

@("build_primitives.resolve.recipe.applyTemplate.platformAndFiles")
@safe unittest
{
    import sparkles.build_primitives.resolve.driver : MemoryDriver;

    auto driver = new MemoryDriver(["/p/src/b.d": "", "/p/src/a.d": "", "/p/src/.hidden/x.d": "",
        "/p/src/app.d": "", "/p/src/c.h": "", "/p/views/t.txt": "", "/p/inc/i.di": ""]);
    SettingsTemplate t;
    t.sourcePaths[""] = ["src"];
    t.importPaths[""] = ["src", "inc"];
    t.stringImportPaths[""] = ["views"];
    t.excludedSourceFiles[""] = ["src/app.d"];
    t.dflags[""] = ["-a"];
    t.dflags["linux-ldc"] = ["-b"];
    t.dflags["windows"] = ["-w"];
    t.versions["posix"] = ["P"];

    BuildSettings s;
    applyTemplate(t, s, BuildPlatform(["linux", "posix"], ["x86_64"], "ldc"), "/p", driver);
    assert(s.sourceFiles == ["src/a.d", "src/b.d"]);
    assert(s.importFiles == ["inc/i.di"]);
    assert(s.stringImportFiles == ["views/t.txt"]);
    assert(s.dflags.length == 2 && s.dflags.canFind("-a") && s.dflags.canFind("-b"));
    assert(s.versions == ["P"] && s.importPaths == ["src", "inc"]);
}

@("build_primitives.resolve.recipe.fillWithDefaults.dubDefaults")
@safe unittest
{
    import sparkles.build_primitives.resolve.driver : MemoryDriver;

    auto driver = new MemoryDriver(["/p/source/app.d": "", "/p/views/v": ""]);
    SettingsTemplate top;
    ConfigurationTemplate[] configurations;
    fillWithDefaults(top, configurations, "p", "/p", driver);
    assert(top.sourcePaths[""] == ["source/"] && top.importPaths[""] == ["source/"]);
    assert(top.stringImportPaths[""] == ["views"]);
    assert(configurations.length == 2);
    assert(configurations[0].name == "application" && configurations[0].settings.mainSourceFile == "source/app.d");
    assert(configurations[1].name == "library"
        && configurations[1].settings.excludedSourceFiles[""] == ["source/app.d"]);

    // An explicit, empty `sourcePaths` keeps dub from adding its default.
    SettingsTemplate none;
    none.sourcePaths[""] = null;
    none.targetType = TargetType.sourceLibrary;
    ConfigurationTemplate[] noConfigurations;
    fillWithDefaults(none, noConfigurations, "p", "/p", driver);
    assert(none.sourcePaths[""].length == 0 && none.importPaths[""] == ["source/"]);
    assert(noConfigurations.length == 1 && noConfigurations[0].settings.targetType == TargetType.sourceLibrary);
}
