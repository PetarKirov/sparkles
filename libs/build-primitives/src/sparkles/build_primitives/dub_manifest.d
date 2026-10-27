/**
The `dub.sdl` vocabulary as a sparkles:wired schema: one set of D types for
everything in this repository that reads a DUB recipe.

$(LREF DubManifest) is the recipe; its build settings, which DUB allows at the
top level, in a `configuration`, and in a `buildType`, are spelled once
($(LREF DubBuildSettingFields)) and read back uniformly as
$(LREF DubBuildSettings). A platform-qualified setting
(`dflags "-O" platform="ldc"`) keeps its platform beside its values
($(LREF DubPlatformValues)).

Recipes are parsed under the `sdlDubRecipe` profile — DUB's own syntax,
string and boolean scalars only — and decoded by wired, so a recipe is read
exactly once, by one parser, wherever it is needed. Tags the schema does not
name are ignored, as DUB's own extension tags (`x:ddoxFilterArgs`) must be.

The schema describes what a recipe $(I states). What a build resolves from it
(import paths, versions, the effective flags) is `dub describe`'s to report.
*/
module sparkles.build_primitives.dub_manifest;

import std.conv : text;

import sparkles.wired : WireName, WireOptional;
import sparkles.wired.sdl : Sdl, SdlAttribute, SdlError, SdlErrorCode, SdlErrorStage,
    SdlExpected, SdlTagValue, fromSDL, parseEmbeddedSdlDocument, readSDLFile, sdlDubRecipe,
    sdlErr;

/// One occurrence of a list-valued setting: its values and, when the
/// occurrence is platform-qualified, the platform (`platform="linux-ldc"`).
struct DubPlatformValues
{
    @SdlTagValue(0) string[] values; ///
    @WireOptional() @SdlAttribute() string platform; ///
}

/// A `dependency` declaration.
struct DubDependency
{
    /// The package name, `root` or `root:sub`.
    @SdlTagValue(0) string name;
    @WireOptional():
    @WireName!Sdl("version") @SdlAttribute() string version_; /// version specification
    @SdlAttribute() string path;       /// a path dependency's directory, as written
    @SdlAttribute() string repository; /// a repository dependency's URL
    @SdlAttribute() bool optional;     ///
    @WireName!Sdl("default") @SdlAttribute() bool default_; /// whether an optional dependency is on by default

    /// The root package of `name`: `sparkles` for `sparkles:base`.
    string rootName() const @safe pure nothrow @nogc => name[0 .. separator];

    /// The subpackage part of `name`; empty for a root package.
    string subPackageName() const @safe pure nothrow @nogc
        => separator < name.length ? name[separator + 1 .. $] : null;

    // The index of the `:` that splits `name`, or its length.
    private size_t separator() const @safe pure nothrow @nogc
    {
        foreach (i, c; name)
            if (c == ':')
                return i;
        return name.length;
    }
}

/// A `subConfiguration "<dependency>" "<configuration>"` selection.
struct DubSubConfiguration
{
    @SdlTagValue(0) string dependency;    ///
    @SdlTagValue(1) string configuration; ///
}

/**
The build-setting fields DUB accepts at the top level of a recipe, in a
`configuration`, and in a `buildType`. Mixed into each of those declarations,
together with `buildSettings()`, which views the fields as a
$(LREF DubBuildSettings).
*/
mixin template DubBuildSettingFields()
{
    @WireName!Sdl("dependency") DubDependency[] dependencies; ///
    @WireName!Sdl("subConfiguration") DubSubConfiguration[] subConfigurations; ///

    DubPlatformValues[] dflags;               ///
    DubPlatformValues[] lflags;               ///
    DubPlatformValues[] libs;                 ///
    DubPlatformValues[] versions;             ///
    DubPlatformValues[] debugVersions;        ///
    DubPlatformValues[] importPaths;          ///
    DubPlatformValues[] sourcePaths;          ///
    DubPlatformValues[] sourceFiles;          ///
    DubPlatformValues[] excludedSourceFiles;  ///
    DubPlatformValues[] stringImportPaths;    ///
    DubPlatformValues[] copyFiles;            ///
    DubPlatformValues[] extraDependencyFiles; ///
    DubPlatformValues[] preGenerateCommands;  ///
    DubPlatformValues[] postGenerateCommands; ///
    DubPlatformValues[] preBuildCommands;     ///
    DubPlatformValues[] postBuildCommands;    ///
    DubPlatformValues[] buildRequirements;    ///
    DubPlatformValues[] buildOptions;         ///

    @WireOptional() string targetType;       ///
    @WireOptional() string targetName;       ///
    @WireOptional() string targetPath;       ///
    @WireOptional() string workingDirectory; ///
    @WireOptional() string mainSourceFile;   ///

    /// These settings alone, without the declaration that holds them.
    const(DubBuildSettings) buildSettings() const return scope @safe pure nothrow @nogc
        => mixin("const(DubBuildSettings)(", dubBuildSettingArguments, ")");
}

/// Build settings on their own: what a top-level recipe, a configuration,
/// and a build type each declare.
struct DubBuildSettings
{
    mixin DubBuildSettingFields;
}

/// `name, …` for every field, in declaration order, of $(LREF DubBuildSettings).
private enum string dubBuildSettingArguments = ()
{
    import std.traits : FieldNameTuple;

    string arguments;
    static foreach (name; FieldNameTuple!DubBuildSettings)
        arguments ~= name ~ ", ";
    return arguments;
}();

/// A `configuration "<name>" { … }` block.
struct DubConfiguration
{
    @SdlTagValue(0) string name; ///
    string[] platforms;          /// the platforms it is restricted to, if any
    mixin DubBuildSettingFields;
}

/// A `buildType "<name>" { … }` block.
struct DubBuildType
{
    @SdlTagValue(0) string name; ///
    mixin DubBuildSettingFields;
}

/// A subpackage: by path (`subPackage "libs/x"`) or inline
/// (`subPackage { name "x" … }`).
struct DubSubPackage
{
    @WireOptional():
    /// The referenced directory, as written; empty for an inline block.
    @SdlTagValue(0) string path;
    /// The inline block's `name`; empty for a path reference, whose name is
    /// the referenced directory's own recipe's.
    string name;
}

/// A `dub.sdl` recipe.
struct DubManifest
{
    @WireOptional():
    string name;        ///
    string description; ///
    string homepage;    ///
    string copyright;   ///
    string license;     ///
    @WireName!Sdl("version") string version_; /// the package version, when the recipe pins one
    string[] authors;   ///
    string[] platforms; /// the platforms the package builds on, if restricted

    @WireName!Sdl("subPackage") DubSubPackage[] subPackages;        ///
    @WireName!Sdl("configuration") DubConfiguration[] configurations; /// in declaration order
    @WireName!Sdl("buildType") DubBuildType[] buildTypes;            /// in declaration order

    mixin DubBuildSettingFields;

    /// The configuration named `name`, or null.
    const(DubConfiguration)* configuration(scope const(char)[] name) const return @safe pure nothrow @nogc
    {
        foreach (ref c; configurations)
            if (c.name == name)
                return &c;
        return null;
    }
}

/// Every value of `entries`, in order, whatever platform each occurrence
/// names: a lazy range over the entries' own arrays.
auto valuesOf(return scope const(DubPlatformValues)[] entries) @safe pure nothrow @nogc
{
    import std.algorithm.iteration : joiner, map;

    return entries.map!(entry => entry.values).joiner;
}

/// Parses `dub.sdl` text.
SdlExpected!DubManifest parseDubManifest(scope const(char)[] text, scope const(char)[] sourceName = null) @safe pure
    => fromSDL!(DubManifest, sdlDubRecipe)(text, sourceName);

/**
Reads a recipe: a `dub.sdl`, or a `.d` single-file package whose leading
`/+ dub.sdl: … +/` comment holds one. Positions in an error are the file's own
either way.
*/
SdlExpected!DubManifest readDubManifest(string path) @safe
{
    if (!(path.length >= 2 && path[$ - 2 .. $] == ".d"))
        return readSDLFile!(DubManifest, sdlDubRecipe)(path);

    import std.file : readText;

    string source;
    try
        source = readText(path);
    catch (Exception)
        return sdlErr!DubManifest(fileFailure(path, "cannot read the file"));
    return parseEmbeddedDubManifest(source, path);
}

/**
Parses the recipe a single-file package `host` embeds
($(REF parseEmbeddedSdlDocument, sparkles,wired,sdl,embedded)), reporting the
host's own positions; a host without an SDL recipe is a `fileReadFailed` error.
*/
SdlExpected!DubManifest parseEmbeddedDubManifest(scope const(char)[] host,
    scope const(char)[] sourceName = null) @safe pure
{
    auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(host, sourceName);
    if (!embedded.recipe.found || embedded.recipe.isJson)
        return sdlErr!DubManifest(fileFailure(sourceName, "no embedded dub.sdl recipe"));
    if (embedded.parsed.hasError)
        return sdlErr!DubManifest(embedded.parsed.error);
    auto decoded = fromSDL!DubManifest(embedded.parsed.document.root);
    if (decoded.hasError)
    {
        auto failure = decoded.error;
        failure.sourceName ~= sourceName;
        return sdlErr!DubManifest(failure);
    }
    return decoded;
}

private SdlError fileFailure(scope const(char)[] path, string reason) @safe pure nothrow
{
    SdlError error;
    error.stage = SdlErrorStage.fileRead;
    error.code = SdlErrorCode.fileReadFailed;
    error.sourceName ~= path;
    error.filePath ~= path;
    error.reason ~= reason;
    return error;
}

@("build_primitives.dub_manifest.parseDubManifest.everyChannel")
@safe pure unittest
{
    import std.algorithm.comparison : equal;

    const parsed = parseDubManifest(`name "m"
description "a \"quoted\" one"
authors "a" "b"
authors "c"
platforms "linux" "osx"
// A comment, and a continued line.
dflags "-preview=in" \
    "-preview=dip1000"
dflags "-O" platform="ldc"
dependency "sparkles:base" path="../.."
dependency "silly" version="~>1.1" optional=true default=true
x:ddoxFilterArgs "--min-protection=Public"
subPackage "libs/alpha"
subPackage {
    name "beta"
    targetType "library"
}
configuration "gpu" {
    platforms "linux"
    targetType "sourceLibrary"
    subConfiguration "sparkles:ui" "testing"
    libs "vulkan"
}
buildType "checked" {
    buildOptions "optimize" "inline"
}
`, "dub.sdl");
    assert(parsed.hasValue, parsed.error.text);
    const m = parsed.value;
    assert(m.name == "m" && m.description == `a "quoted" one`);
    assert(m.authors == ["a", "b", "c"] && m.platforms == ["linux", "osx"]);
    assert(m.dflags == [DubPlatformValues(["-preview=in", "-preview=dip1000"]),
        DubPlatformValues(["-O"], "ldc")]);
    assert(m.dflags.valuesOf.equal(["-preview=in", "-preview=dip1000", "-O"]));
    assert(m.dependencies[0].path == "../.." && m.dependencies[0].rootName == "sparkles"
        && m.dependencies[0].subPackageName == "base");
    assert(m.dependencies[1].version_ == "~>1.1" && m.dependencies[1].optional
        && m.dependencies[1].default_ && m.dependencies[1].subPackageName is null);
    assert(m.subPackages == [DubSubPackage(path: "libs/alpha"), DubSubPackage(name: "beta")]);

    const gpu = m.configuration("gpu");
    assert(gpu !is null && m.configuration("absent") is null);
    assert(gpu.platforms == ["linux"] && gpu.targetType == "sourceLibrary");
    assert(gpu.subConfigurations == [DubSubConfiguration("sparkles:ui", "testing")]);
    assert(gpu.buildSettings.libs.valuesOf.equal(["vulkan"]));
    assert(m.buildSettings.dependencies.length == 2);
    assert(m.buildTypes[0].name == "checked"
        && m.buildTypes[0].buildOptions.valuesOf.equal(["optimize", "inline"]));
}

@("build_primitives.dub_manifest.parseDubManifest.rejectsWhatDubRejects")
@safe pure unittest
{
    assert(parseDubManifest(`configuration "x" {`).hasError);
    // A recipe holds strings and booleans; a number is no recipe value.
    assert(parseDubManifest(`x:build 3`).hasError);
    // A singular setting stated twice is ambiguous, never last-one-wins.
    assert(parseDubManifest("targetType \"library\"\ntargetType \"executable\"\n").hasError);
}

@("build_primitives.dub_manifest.parseEmbeddedDubManifest.hostPositions")
@safe pure unittest
{
    const source = "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"s\"\n    bad =\n+/\nvoid main() {}\n";
    const parsed = parseEmbeddedDubManifest(source, "x.d");
    assert(parsed.hasError);
    assert(parsed.error.startPosition.line == 4, parsed.error.text);
    assert(parseEmbeddedDubManifest("/+dub.sdl: name \"n\" +/").value.name == "n");
    assert(parseEmbeddedDubManifest("/+dub.json: {} +/").hasError);
    assert(parseEmbeddedDubManifest("module m;\n/+ dub.sdl: +/").hasError);
}

@("build_primitives.dub_manifest.readDubManifest.hostLinesPastLoneCrAndU2028")
@system unittest
{
    import std.path : buildPath;
    import sparkles.test_utils.tmpfs : TmpFS;

    // A lone CR and U+2028 before the recipe each end a line of the host;
    // the error reports the host's line, not one counted from `\n` alone.
    auto tmp = TmpFS.create("sparkles-build-primitives-lines");
    tmp.writeFileAt("cr.d", "#!/usr/bin/env dub\n\r/+ dub.sdl:\n    bad =\n+/\n");
    tmp.writeFileAt("ls.d", "#!/usr/bin/env dub\n/+ dub.sdl:\u2028    bad =\n+/\n");
    assert(readDubManifest(tmp.dir.buildPath("cr.d")).error.startPosition.line == 4);
    assert(readDubManifest(tmp.dir.buildPath("ls.d")).error.startPosition.line == 3);
}

@("build_primitives.dub_manifest.DubDependency.names")
@safe pure nothrow @nogc unittest
{
    const dependency = DubDependency("sparkles:base");
    assert(dependency.rootName == "sparkles" && dependency.subPackageName == "base");
    assert(DubDependency("silly").subPackageName is null);
}

@("build_primitives.dub_manifest.readDubManifest.forms")
@system unittest
{
    import std.path : buildPath;
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.wired.sdl : SdlErrorCode;

    auto tmp = TmpFS.create("sparkles-build-primitives-manifest");
    tmp.writeFileAt("dub.sdl", "name \"p\"\n");
    tmp.writeFileAt("single.d", "/+ dub.sdl:\n    name \"s\"\n+/\nvoid main() {}\n");
    tmp.writeFileAt("plain.d", "module plain;\n");

    assert(readDubManifest(tmp.dir.buildPath("dub.sdl")).value.name == "p");
    assert(readDubManifest(tmp.dir.buildPath("single.d")).value.name == "s");
    assert(readDubManifest(tmp.dir.buildPath("plain.d")).error.code == SdlErrorCode.fileReadFailed);
    assert(readDubManifest(tmp.dir.buildPath("absent.sdl")).error.code == SdlErrorCode.fileReadFailed);
}

@("build_primitives.dub_manifest.readDubManifest.everyRecipeInThisRepository")
@system unittest
{
    import std.algorithm.searching : endsWith;
    import std.file : exists, readText;
    import std.path : buildNormalizedPath, dirName;
    import std.string : lineSplitter;
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.test_runner.skip : skipTest;

    // Every tracked recipe, standalone or embedded in a single-file package,
    // must decode: a reader that met a failure would see a package with no
    // name, subpackages, or platform restriction.
    const root = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");
    const listed = runGit(["ls-files", "*dub.sdl", "*.d"], root);
    if (listed.status != 0)
        return skipTest("not a git checkout: " ~ root);

    size_t recipes;
    foreach (file; listed.output.lineSplitter)
    {
        const path = root.buildNormalizedPath(file);
        if (!path.exists)
            continue;
        if (path.endsWith(".d"))
        {
            import sparkles.wired.sdl : locateEmbeddedRecipe;

            const embedded = locateEmbeddedRecipe(path.readText);
            if (!embedded.found || embedded.isJson)
                continue;
        }
        const manifest = readDubManifest(path);
        assert(manifest.hasValue, manifest.error.text);
        ++recipes;
    }
    assert(recipes > 100);
}
