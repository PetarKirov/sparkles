/**
The DUB recipe vocabulary as a sparkles:wired schema: one set of D types for
everything in this repository that reads a DUB recipe, from `dub.sdl` or from
a registry package's `dub.json` (build-graph SPEC BGR1).

$(LREF DubManifest) is the recipe; its build settings, which DUB allows at the
top level, in a `configuration`, and in a `buildType`, are spelled once
($(LREF DubBuildSettingFields)) and read back uniformly as
$(LREF DubBuildSettings). A platform-qualified setting
(`dflags "-O" platform="ldc"`, or `"dflags-ldc"` in JSON) keeps its platform
beside its values ($(LREF DubPlatformValues)).

SDL recipes are parsed under the `sdlDubRecipe` profile — DUB's own syntax,
string and boolean scalars only — and decoded by wired, so a recipe is read
exactly once, by one parser, wherever it is needed. JSON recipes are read
with `std.json` into the same types ($(LREF parseDubJsonManifest)).

Reading is strict: a directive, attribute or value the schema does not name is
an error naming the file, line and directive. dub's extension tags (`x:` in
SDL, a leading `-` in JSON) are the only exception: they are read and ignored,
except `x:versionFilters` and `x:debugVersionFilters`, which dub honours.

The schema describes what a recipe $(I states). What a build resolves from it
is `sparkles.build_primitives.resolve`'s to compute.
*/
module sparkles.build_primitives.dub_manifest;

import std.conv : text;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.wired : WireName, WireOptional, WireSkip;
import sparkles.wired.sdl : OwnedSdlExtras, Sdl, SdlAttribute, SdlError, SdlErrorCode,
    SdlErrorStage, SdlExpected, SdlExtra, SdlExtraChannel, SdlPosition, SdlSpan, SdlTagValue,
    fromSDL, locateEmbeddedRecipe, parseEmbeddedSdlDocument, parseSdlDocument, readSDLFile,
    sdlDubRecipe, sdlErr, sdlOk, writeEmbeddedRendering;

/// One occurrence of a list-valued setting: its values and, when the
/// occurrence is platform-qualified, the platform (`platform="linux-ldc"`).
struct DubPlatformValues
{
    @SdlTagValue(0) string[] values; ///
    @WireOptional(WireSkip.whenDefault) @SdlAttribute() string platform; ///
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty
}

/// A `dependency` declaration.
struct DubDependency
{
    /// The package name, `root` or `root:sub`.
    @SdlTagValue(0) string name;
    @WireOptional(WireSkip.whenDefault):
    @WireName!Sdl("version") @SdlAttribute() string version_; /// version specification
    @SdlAttribute() string path;       /// a path dependency's directory, as written
    @SdlAttribute() string repository; /// a repository dependency's URL
    @SdlAttribute() bool optional;     ///
    @WireName!Sdl("default") @SdlAttribute() bool default_; /// whether an optional dependency is on by default
    /// The platform the dependency applies on (`platform="posix"`); empty
    /// for every platform.
    @SdlAttribute() string platform;
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty

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
    @SdlExtra() OwnedSdlExtras unknown;   /// what the schema does not name; must be empty
}

/// `toolchainRequirements dub=">=1.30" frontend=">=2.105"`: the version
/// ranges a package needs of each tool, as written.
struct DubToolchainRequirements
{
    @WireOptional(WireSkip.whenDefault):
    @SdlAttribute() string dub;      ///
    @SdlAttribute() string frontend; ///
    @SdlAttribute() string dmd;      ///
    @SdlAttribute() string ldc;      ///
    @SdlAttribute() string gdc;      ///
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty
}

/**
The build-setting fields DUB accepts at the top level of a recipe, in a
`configuration`, and in a `buildType`. Mixed into each of those declarations,
together with `buildSettings()`, which views the fields as a
$(LREF DubBuildSettings). Every declaration that mixes it in also declares
`@SdlExtra() OwnedSdlExtras unknown`.
*/
mixin template DubBuildSettingFields()
{
    @WireName!Sdl("dependency") DubDependency[] dependencies; ///
    @WireName!Sdl("subConfiguration") DubSubConfiguration[] subConfigurations; ///

    DubPlatformValues[] dflags;               ///
    DubPlatformValues[] lflags;               ///
    DubPlatformValues[] libs;                 ///
    DubPlatformValues[] frameworks;           ///
    DubPlatformValues[] versions;             ///
    DubPlatformValues[] debugVersions;        ///
    @WireName!Sdl("x:versionFilters") DubPlatformValues[] versionFilters;           ///
    @WireName!Sdl("x:debugVersionFilters") DubPlatformValues[] debugVersionFilters; ///
    DubPlatformValues[] importPaths;          ///
    DubPlatformValues[] cImportPaths;         ///
    DubPlatformValues[] sourcePaths;          ///
    DubPlatformValues[] cSourcePaths;         ///
    DubPlatformValues[] sourceFiles;          ///
    DubPlatformValues[] excludedSourceFiles;  ///
    DubPlatformValues[] injectSourceFiles;    ///
    DubPlatformValues[] stringImportPaths;    ///
    DubPlatformValues[] copyFiles;            ///
    DubPlatformValues[] extraDependencyFiles; ///
    DubPlatformValues[] preGenerateCommands;  ///
    DubPlatformValues[] postGenerateCommands; ///
    DubPlatformValues[] preBuildCommands;     ///
    DubPlatformValues[] postBuildCommands;    ///
    DubPlatformValues[] preRunCommands;       ///
    DubPlatformValues[] postRunCommands;      ///
    /// `environments "NAME" "value"`, and the per-phase forms below: each
    /// occurrence's values are one name and its value.
    DubPlatformValues[] environments;
    DubPlatformValues[] buildEnvironments;        /// ditto
    DubPlatformValues[] runEnvironments;          /// ditto
    DubPlatformValues[] preGenerateEnvironments;  /// ditto
    DubPlatformValues[] postGenerateEnvironments; /// ditto
    DubPlatformValues[] preBuildEnvironments;     /// ditto
    DubPlatformValues[] postBuildEnvironments;    /// ditto
    DubPlatformValues[] preRunEnvironments;       /// ditto
    DubPlatformValues[] postRunEnvironments;      /// ditto
    DubPlatformValues[] buildRequirements;    ///
    DubPlatformValues[] buildOptions;         ///

    @WireOptional(WireSkip.whenDefault) string targetType;         ///
    @WireOptional(WireSkip.whenDefault) string targetName;         ///
    @WireOptional(WireSkip.whenDefault) string targetPath;         ///
    @WireOptional(WireSkip.whenDefault) string workingDirectory;   ///
    @WireOptional(WireSkip.whenDefault) string mainSourceFile;     ///
    @WireOptional(WireSkip.whenDefault) string systemDependencies; ///

    /// These settings alone, without the declaration that holds them.
    const(DubBuildSettings) buildSettings() const return scope @safe pure nothrow @nogc
        => mixin("const(DubBuildSettings)(", dubBuildSettingArguments, ")");
}

/// Build settings on their own: what a top-level recipe, a configuration,
/// and a build type each declare.
struct DubBuildSettings
{
    mixin DubBuildSettingFields;
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty
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
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty
}

/// A `buildType "<name>" { … }` block.
struct DubBuildType
{
    @SdlTagValue(0) string name; ///
    mixin DubBuildSettingFields;
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty
}

/**
What a recipe and an inline `subPackage` block both state: the package's own
fields, its configurations and build types, and its top-level build
settings. Every declaration that mixes it in also declares
`@SdlExtra() OwnedSdlExtras unknown`.
*/
mixin template DubPackageFields()
{
    @WireOptional(WireSkip.whenDefault):
    string name;        ///
    string description; ///
    string homepage;    ///
    string copyright;   ///
    string license;     ///
    @WireName!Sdl("version") string version_; /// the package version, when the recipe pins one
    string[] authors;   ///
    /// The platforms the package builds on, if restricted. dub itself
    /// ignores the top-level form (only a configuration's `platforms`
    /// selects); `ci` reads it to skip a single-file example.
    string[] platforms;
    DubToolchainRequirements toolchainRequirements; ///

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

/**
A subpackage: by path (`subPackage "libs/x"`) or inline
(`subPackage { name "x" … }`), in which case it holds the inline recipe.
dub allows no subpackages inside a subpackage.
*/
struct DubSubPackage
{
    /// The referenced directory, as written; empty for an inline block.
    @WireOptional(WireSkip.whenDefault) @SdlTagValue(0) string path;
    mixin DubPackageFields;
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty

    /// Whether the subpackage is an inline block rather than a path.
    bool isInline() const @safe pure nothrow @nogc => path.length == 0;
}

/// A DUB recipe.
struct DubManifest
{
    mixin DubPackageFields;
    @WireOptional(WireSkip.whenDefault) @WireName!Sdl("subPackage") DubSubPackage[] subPackages; ///
    @SdlExtra() OwnedSdlExtras unknown; /// what the schema does not name; must be empty
}

/// Every value of `entries`, in order, whatever platform each occurrence
/// names: a lazy range over the entries' own arrays.
auto valuesOf(return scope const(DubPlatformValues)[] entries) @safe pure nothrow @nogc
{
    import std.algorithm.iteration : joiner, map;

    return entries.map!(entry => entry.values).joiner;
}

/// dub platform OS tokens describing the host this binary was built for.
string[] hostPlatformTokens() @safe pure nothrow
{
    version (Windows)
        return ["windows"];
    else version (OSX)
        return ["osx", "darwin", "posix"];
    else version (linux)
        return ["linux", "posix"];
    else version (FreeBSD)
        return ["freebsd", "posix"];
    else version (Posix)
        return ["posix"];
    else
        return [];
}

/**
Whether a recipe declaring `declared` platforms is buildable on a host
described by `hostTokens` ($(LREF hostPlatformTokens)). No declaration means
no restriction. A dub platform spec may be `os`, `os-arch`, or
`os-arch-compiler`; only the leading OS component is matched.
*/
bool platformsAllowHost(const(string)[] declared, const(string)[] hostTokens) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    if (declared.length == 0)
        return true;

    foreach (spec; declared)
    {
        size_t dash = spec.length;
        foreach (i, c; spec)
            if (c == '-')
            {
                dash = i;
                break;
            }
        if (hostTokens.canFind(spec[0 .. dash]))
            return true;
    }
    return false;
}

///
@("build_primitives.dub_manifest.platformsAllowHost.matching")
@safe pure nothrow unittest
{
    // No declaration => runs anywhere.
    assert(platformsAllowHost([], ["osx", "darwin", "posix"]));
    // Linux-only: runs on Linux, skipped on macOS.
    assert(platformsAllowHost(["linux"], ["linux", "posix"]));
    assert(!platformsAllowHost(["linux"], ["osx", "darwin", "posix"]));
    // `posix` matches any POSIX host; OS component of a compound spec is matched.
    assert(platformsAllowHost(["posix"], ["linux", "posix"]));
    assert(platformsAllowHost(["linux-x86_64"], ["linux", "posix"]));
    assert(!platformsAllowHost(["windows"], ["linux", "posix"]));
}

/// Parses `dub.sdl` text, rejecting what the schema does not name.
SdlExpected!DubManifest parseDubManifest(scope const(char)[] text, scope const(char)[] sourceName = null) @safe pure
{
    auto parsed = parseSdlDocument!sdlDubRecipe(text, sourceName);
    if (parsed.hasError)
        return sdlErr!DubManifest(parsed.error);
    return decodeRecipe(parsed.document, sourceName);
}

/**
Reads a recipe: a `dub.sdl`, a `dub.json`, or a `.d` single-file package
whose leading `/+ dub.sdl: … +/` (or `dub.json`) comment holds one
($(LREF parseEmbeddedDubManifest)). Positions in an error are the file's own
either way.
*/
SdlExpected!DubManifest readDubManifest(string path) @safe
{
    import std.file : readText;

    string source;
    try
        source = readText(path);
    catch (Exception)
        return sdlErr!DubManifest(fileFailure(path, "cannot read the file"));
    return parseDubRecipeText(source, path);
}

/// Parses a recipe file's text, its form chosen by `path`'s extension as in
/// $(LREF readDubManifest).
SdlExpected!DubManifest parseDubRecipeText(scope const(char)[] source, string path) @safe
{
    const extension = path.length >= 5 && path[$ - 5 .. $] == ".json" ? ".json"
        : path.length >= 2 && path[$ - 2 .. $] == ".d" ? ".d" : ".sdl";
    if (extension == ".json")
        return parseDubJsonManifest(source, path);
    if (extension == ".sdl")
        return parseDubManifest(source, path);

    const embedded = locateEmbeddedRecipe(source);
    if (!embedded.found)
        return sdlErr!DubManifest(fileFailure(path, "no embedded dub recipe"));
    if (!embedded.isJson)
        return parseEmbeddedDubManifest(source, path);
    // The host with every byte outside the recipe blanked is JSON whitespace
    // there, so an error reports the host's own line and column.
    UniqueBuffer!char text;
    writeEmbeddedRendering(text, source, embedded);
    return parseDubJsonManifest(text[], path);
}

/**
Parses the recipe a single-file package `host` embeds
($(REF parseEmbeddedSdlDocument, sparkles,wired,sdl,embedded)), rejecting what
the schema does not name and reporting the host's own positions; a host
without an SDL recipe is a `fileReadFailed` error.
*/
SdlExpected!DubManifest parseEmbeddedDubManifest(scope const(char)[] host,
    scope const(char)[] sourceName = null) @safe pure
{
    auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(host, sourceName);
    if (!embedded.recipe.found || embedded.recipe.isJson)
        return sdlErr!DubManifest(fileFailure(sourceName, "no embedded dub.sdl recipe"));
    if (embedded.parsed.hasError)
        return sdlErr!DubManifest(embedded.parsed.error);
    return decodeRecipe(embedded.parsed.document, sourceName);
}

// Decodes a parsed recipe document, rejecting what the schema does not name.
private SdlExpected!DubManifest decodeRecipe(Document)(const ref Document document,
    scope const(char)[] sourceName)
{
    auto decoded = fromSDL!DubManifest(document.root);
    if (decoded.hasError)
    {
        auto failure = decoded.error;
        failure.sourceName ~= sourceName;
        return sdlErr!DubManifest(failure);
    }
    return rejectUnknown(decoded, document, sourceName);
}

/// `decoded`, or the error naming the first occurrence — in source order —
/// that the schema does not name, positioned in `document`. An `x:` child
/// tag is dub's extension namespace, read and ignored.
private SdlExpected!DubManifest rejectUnknown(Document)(SdlExpected!DubManifest decoded,
    const ref Document document, scope const(char)[] sourceName)
{
    Unknown first;
    findUnknown(decoded.value, first);
    if (!first.found)
        return decoded;
    SdlError error;
    error.stage = SdlErrorStage.decode;
    error.code = SdlErrorCode.unknownMember;
    error.targetType = "a DUB recipe";
    error.sourceName ~= sourceName;
    error.span = first.span;
    error.startPosition = document.position(first.span.startOffset);
    error.endPosition = document.position(first.span.endOffset);
    error.reason ~= first.what;
    return sdlErr!DubManifest(error);
}

// The earliest unknown occurrence found so far.
private struct Unknown
{
    bool found;
    SdlSpan span;
    string what;
}

// Walks every aggregate of `value`, keeping the earliest unknown occurrence.
private void findUnknown(T)(const ref T value, ref Unknown first) @safe pure
{
    static foreach (i, Field; typeof(T.tupleof))
    {{
        alias F = typeof(T.tupleof[i]);
        static if (is(F == OwnedSdlExtras))
        {
            foreach (ref member; value.tupleof[i].members)
            {
                if (member.channel == SdlExtraChannel.child && member.name.namespace_ == "x")
                    continue;
                if (first.found && first.span.startOffset <= member.span.startOffset)
                    continue;
                const name = member.name.namespace_.length
                    ? text(member.name.namespace_, ":", member.name.localName)
                    : member.name.localName.idup;
                first = Unknown(true, member.span,
                    member.channel == SdlExtraChannel.child ? text("unknown directive `", name, "`")
                    : member.channel == SdlExtraChannel.attribute ? text("unknown attribute `", name, "`")
                    : "unexpected value");
            }
        }
        else static if (is(F == struct))
            findUnknown(value.tupleof[i], first);
        else static if (is(F == E[], E) && is(E == struct))
            foreach (ref element; value.tupleof[i])
                findUnknown(element, first);
    }}
}


/**
Parses a `dub.json` recipe into the same schema as `dub.sdl`, with dub's JSON
spellings: `dependencies`, `subConfigurations`, `configurations` and
`buildTypes` as objects or arrays, a dependency given by its version string
alone, and a platform as a key suffix (`"dflags-linux-ldc"`), which becomes
$(LREF DubPlatformValues.platform).

A key the schema does not name is an error, located at the key's first
occurrence in the text (`std.json` records no positions). A key with a
leading `-` is dub's extension namespace, ignored as dub ignores it.
*/
SdlExpected!DubManifest parseDubJsonManifest(scope const(char)[] text, scope const(char)[] sourceName = null) @safe
{
    import std.json : JSONException, JSONType, JSONValue, parseJSON;

    JsonRecipeReader reader;
    JSONValue root;
    try
        root = parseJSON(text);
    catch (JSONException e)
        return sdlErr!DubManifest(jsonFailure(text, sourceName, null, "invalid JSON: " ~ e.msg));
    DubManifest manifest;
    if (!reader.package_(root, manifest))
        return sdlErr!DubManifest(jsonFailure(text, sourceName, reader.failedKey, reader.reason));
    return sdlOk(manifest);
}

// Reads one JSON recipe, keeping the first failure: its key and reason.
private struct JsonRecipeReader
{
    import std.json : JSONType, JSONValue;

    string failedKey;
    string reason;

    // The recipe fields of a package (the root or an inline subpackage).
    bool package_(R)(const JSONValue json, ref R recipe) @safe
    {
        if (!expect(json, JSONType.object, "a package"))
            return false;
        foreach (key, value; json.objectNoRef)
            if (!packageField(key, value, recipe))
                return false;
        return true;
    }

    bool packageField(R)(string key, const JSONValue value, ref R recipe) @safe
    {
        switch (key)
        {
        case "name": return str(key, value, recipe.name);
        case "version": return str(key, value, recipe.version_);
        case "description": return str(key, value, recipe.description);
        case "homepage": return str(key, value, recipe.homepage);
        case "copyright": return str(key, value, recipe.copyright);
        case "license": return str(key, value, recipe.license);
        case "authors": return strs(key, value, recipe.authors);
        case "platforms": return strs(key, value, recipe.platforms);
        case "toolchainRequirements": return toolchain(key, value, recipe.toolchainRequirements);
        case "configurations":
            if (!expect(value, JSONType.array, key))
                return false;
            foreach (element; value.arrayNoRef)
            {
                DubConfiguration configuration;
                if (!configuration_(element, configuration))
                    return false;
                recipe.configurations ~= configuration;
            }
            return true;
        case "buildTypes":
            if (!expect(value, JSONType.object, key))
                return false;
            foreach (name, settings; value.objectNoRef)
            {
                auto buildType = DubBuildType(name);
                if (!expect(settings, JSONType.object, name))
                    return false;
                foreach (settingKey, setting; settings.objectNoRef)
                    if (!buildSetting(settingKey, setting, buildType))
                        return false;
                recipe.buildTypes ~= buildType;
            }
            return true;
        case "subPackages":
            static if (is(R == DubManifest))
            {
                if (!expect(value, JSONType.array, key))
                    return false;
                foreach (element; value.arrayNoRef)
                {
                    DubSubPackage sub;
                    if (element.type == JSONType.string)
                        sub.path = element.str;
                    else if (!package_(element, sub))
                        return false;
                    recipe.subPackages ~= sub;
                }
                return true;
            }
            else
                return fail(key, "a subpackage cannot declare subpackages");
        default:
            return buildSetting(key, value, recipe);
        }
    }

    bool configuration_(const JSONValue json, ref DubConfiguration configuration) @safe
    {
        if (!expect(json, JSONType.object, "a configuration"))
            return false;
        foreach (key, value; json.objectNoRef)
        {
            const ok = key == "name" ? str(key, value, configuration.name)
                : key == "platforms" ? strs(key, value, configuration.platforms)
                : buildSetting(key, value, configuration);
            if (!ok)
                return false;
        }
        return true;
    }

    // One build-setting key, `base` or `base-<platform>`, into `settings`.
    bool buildSetting(S)(string key, const JSONValue value, ref S settings) @safe
    {
        import std.string : indexOf;

        if (key.length && key[0] == '-')
            return true;
        const dash = key.indexOf('-');
        const base = dash < 0 ? key : key[0 .. dash];
        const platform = dash < 0 ? null : key[dash + 1 .. $];

        bool scalar(ref string field)
        {
            if (platform.length)
                return fail(key, "`" ~ base ~ "` does not support a platform suffix");
            return str(key, value, field);
        }

        bool list(ref DubPlatformValues[] field)
        {
            DubPlatformValues entry;
            entry.platform = platform;
            if (!strs(key, value, entry.values))
                return false;
            field ~= entry;
            return true;
        }

        bool pairs(ref DubPlatformValues[] field)
        {
            if (!expect(value, JSONType.object, key))
                return false;
            foreach (name, v; value.objectNoRef)
            {
                if (!expect(v, JSONType.string, key))
                    return false;
                field ~= DubPlatformValues([name, v.str], platform);
            }
            return true;
        }

        switch (base)
        {
        case "targetType": return scalar(settings.targetType);
        case "targetName": return scalar(settings.targetName);
        case "targetPath": return scalar(settings.targetPath);
        case "workingDirectory": return scalar(settings.workingDirectory);
        case "mainSourceFile": return scalar(settings.mainSourceFile);
        case "systemDependencies": return scalar(settings.systemDependencies);
        case "dependencies":
            if (platform.length)
                return fail(key, "`dependencies` does not support a platform suffix");
            return dependencies(key, value, settings.dependencies);
        case "subConfigurations":
            if (platform.length)
                return fail(key, "`subConfigurations` does not support a platform suffix");
            if (!expect(value, JSONType.object, key))
                return false;
            foreach (dependency, configuration; value.objectNoRef)
            {
                if (!expect(configuration, JSONType.string, key))
                    return false;
                settings.subConfigurations ~= DubSubConfiguration(dependency, configuration.str);
            }
            return true;
        case "sourcePath":
            DubPlatformValues entry;
            entry.platform = platform;
            entry.values.length = 1;
            if (!str(key, value, entry.values[0]))
                return false;
            settings.sourcePaths ~= entry;
            return true;
        case "files": return list(settings.sourceFiles);
        static foreach (field; listSettingNames)
        {
        case field: return list(__traits(getMember, settings, field));
        }
        static foreach (field; environmentSettingNames)
        {
        case field: return pairs(__traits(getMember, settings, field));
        }
        default:
            return fail(key, "unknown directive `" ~ key ~ "`");
        }
    }

    bool dependencies(string key, const JSONValue value, ref DubDependency[] into) @safe
    {
        if (!expect(value, JSONType.object, key))
            return false;
        foreach (name, spec; value.objectNoRef)
        {
            auto dependency = DubDependency(name);
            if (spec.type == JSONType.string)
                dependency.version_ = spec.str;
            else if (spec.type == JSONType.object)
            {
                foreach (field, v; spec.objectNoRef)
                {
                    bool ok;
                    switch (field)
                    {
                    case "version": ok = str(field, v, dependency.version_); break;
                    case "path": ok = str(field, v, dependency.path); break;
                    case "repository": ok = str(field, v, dependency.repository); break;
                    case "optional": ok = boolean(field, v, dependency.optional); break;
                    case "default": ok = boolean(field, v, dependency.default_); break;
                    default:
                        ok = fail(field, "unknown dependency field `" ~ field ~ "`");
                    }
                    if (!ok)
                        return false;
                }
            }
            else
                return fail(name, "a dependency is a version string or an object");
            into ~= dependency;
        }
        return true;
    }

    bool toolchain(string key, const JSONValue value, ref DubToolchainRequirements into) @safe
    {
        if (!expect(value, JSONType.object, key))
            return false;
        foreach (tool, v; value.objectNoRef)
        {
        tools:
            switch (tool)
            {
            static foreach (field; ["dub", "frontend", "dmd", "ldc", "gdc"])
            {
            case field:
                if (!str(tool, v, __traits(getMember, into, field)))
                    return false;
                break tools;
            }
            default:
                return fail(tool, "unknown toolchain `" ~ tool ~ "`");
            }
        }
        return true;
    }

    bool str(string key, const JSONValue value, ref string into) @safe
    {
        if (!expect(value, JSONType.string, key))
            return false;
        into = value.str;
        return true;
    }

    bool strs(string key, const JSONValue value, ref string[] into) @safe
    {
        if (!expect(value, JSONType.array, key))
            return false;
        foreach (element; value.arrayNoRef)
        {
            if (!expect(element, JSONType.string, key))
                return false;
            into ~= element.str;
        }
        return true;
    }

    bool boolean(string key, const JSONValue value, ref bool into) @safe
    {
        if (value.type != JSONType.true_ && value.type != JSONType.false_)
            return fail(key, "`" ~ key ~ "` must be a boolean");
        into = value.type == JSONType.true_;
        return true;
    }

    bool expect(const JSONValue value, JSONType type, scope const(char)[] key) @safe
    {
        import std.conv : to;

        if (value.type == type)
            return true;
        return fail(key, text("`", key, "` must be a JSON ", type.to!string.stripUnderscore));
    }

    bool fail(scope const(char)[] key, scope const(char)[] why) @safe
    {
        if (reason.length == 0)
        {
            failedKey = key.idup;
            reason = why.idup;
        }
        return false;
    }
}

// An error at the first occurrence of `"key"` in `source`.
private SdlError jsonFailure(scope const(char)[] source, scope const(char)[] sourceName,
    scope const(char)[] key, scope const(char)[] reason) @safe pure
{
    import std.string : indexOf;

    SdlError result;
    result.stage = SdlErrorStage.decode;
    result.code = SdlErrorCode.unknownMember;
    result.targetType = "a DUB recipe";
    result.sourceName ~= sourceName;
    result.reason ~= reason;
    const at = key.length ? source.indexOf(text("\"", key, "\"")) : -1;
    if (at >= 0)
    {
        uint line = 1, column = 1;
        foreach (c; source[0 .. at])
        {
            if (c == '\n')
            {
                ++line;
                column = 1;
            }
            else
                ++column;
        }
        result.span = SdlSpan.at(at);
        result.startPosition = SdlPosition(at, line, column);
        result.endPosition = result.startPosition;
    }
    return result;
}

private string stripUnderscore(string s) @safe pure nothrow @nogc
    => s.length && s[$ - 1] == '_' ? s[0 .. $ - 1] : s;

// The list-valued settings, by their name in both forms.
private immutable string[] listSettingNames = [
    "dflags", "lflags", "libs", "frameworks", "versions", "debugVersions", "importPaths",
    "cImportPaths", "sourcePaths", "cSourcePaths", "sourceFiles", "excludedSourceFiles",
    "injectSourceFiles", "stringImportPaths", "copyFiles", "extraDependencyFiles",
    "preGenerateCommands", "postGenerateCommands", "preBuildCommands", "postBuildCommands",
    "preRunCommands", "postRunCommands", "buildRequirements", "buildOptions",
];

// The name/value-pair settings.
private immutable string[] environmentSettingNames = [
    "environments", "buildEnvironments", "runEnvironments", "preGenerateEnvironments",
    "postGenerateEnvironments", "preBuildEnvironments", "postBuildEnvironments",
    "preRunEnvironments", "postRunEnvironments",
];

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
    assert(m.dflags.length == 2 && m.dflags[0].values == ["-preview=in", "-preview=dip1000"]
        && m.dflags[0].platform is null && m.dflags[1].values == ["-O"] && m.dflags[1].platform == "ldc");
    assert(m.dflags.valuesOf.equal(["-preview=in", "-preview=dip1000", "-O"]));
    assert(m.dependencies[0].path == "../.." && m.dependencies[0].rootName == "sparkles"
        && m.dependencies[0].subPackageName == "base");
    assert(m.dependencies[1].version_ == "~>1.1" && m.dependencies[1].optional
        && m.dependencies[1].default_ && m.dependencies[1].subPackageName is null);
    assert(m.subPackages.length == 2 && m.subPackages[0].path == "libs/alpha"
        && !m.subPackages[0].isInline);
    assert(m.subPackages[1].isInline && m.subPackages[1].name == "beta"
        && m.subPackages[1].targetType == "library");

    const gpu = m.configuration("gpu");
    assert(gpu !is null && m.configuration("absent") is null);
    assert(gpu.platforms == ["linux"] && gpu.targetType == "sourceLibrary");
    assert(gpu.subConfigurations.length == 1 && gpu.subConfigurations[0].dependency == "sparkles:ui"
        && gpu.subConfigurations[0].configuration == "testing");
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

@("build_primitives.dub_manifest.parseDubManifest.rejectsUnknownDirectives")
@safe pure unittest
{
    import std.algorithm.comparison : equal;

    // BGR1: the file, line and directive of the first unknown occurrence.
    const directive = parseDubManifest("name \"p\"\nconfiguration \"c\" {\n    sourcePath \"x\"\n}\n",
        "p/dub.sdl");
    assert(directive.hasError);
    assert(directive.error.startPosition.line == 3, directive.error.text);
    assert(directive.error.text == "p/dub.sdl(3:5): Cannot decode a DUB recipe: unknown directive `sourcePath`",
        directive.error.text);

    const attribute = parseDubManifest("name \"p\"\ndependency \"q\" pth=\"../q\"\n");
    assert(attribute.hasError && attribute.error.startPosition.line == 2);
    assert(attribute.error.reason[] == "unknown attribute `pth`", attribute.error.text);

    const value = parseDubManifest("name \"p\"\nsubConfiguration \"q\" \"c\" \"extra\"\n");
    assert(value.hasError && value.error.reason[] == "unexpected value", value.error.text);

    // Dependency-specific settings are outside the supported vocabulary.
    assert(parseDubManifest("name \"p\"\ndependency \"q\" version=\"*\" {\n    dflags \"-O\"\n}\n")
        .hasError);
    // A subpackage of a subpackage is no DUB form.
    assert(parseDubManifest("name \"p\"\nsubPackage {\n    name \"a\"\n    subPackage \"b\"\n}\n")
        .hasError);

    // The earliest of several unknown occurrences is reported.
    const several = parseDubManifest("name \"p\"\nbuildType \"b\" {\n    bogus \"1\"\n}\nzzz \"2\"\n");
    assert(several.error.startPosition.line == 3, several.error.text);

    // `x:` tags are read and ignored, and dub's version filters are read.
    const extension = parseDubManifest("name \"p\"\nx:ddoxTool \"t\"\nx:versionFilters \"V\"\n");
    assert(extension.hasValue, extension.error.text);
    assert(extension.value.versionFilters.valuesOf.equal(["V"]));
}

@("build_primitives.dub_manifest.parseDubManifest.toolchainAndEnvironments")
@safe pure unittest
{
    import std.algorithm.comparison : equal;

    const parsed = parseDubManifest(`name "p"
toolchainRequirements dub=">=1.30" frontend=">=2.105"
environments "A" "1" platform="linux"
cSourcePaths "c"
cImportPaths "h"
debugVersions "D"
buildRequirements "disallowDeprecations"
mainSourceFile "app.d"
`);
    assert(parsed.hasValue, parsed.error.text);
    const m = parsed.value;
    assert(m.toolchainRequirements.dub == ">=1.30" && m.toolchainRequirements.frontend == ">=2.105");
    assert(m.environments[0].values == ["A", "1"] && m.environments[0].platform == "linux");
    assert(m.cSourcePaths.valuesOf.equal(["c"]) && m.cImportPaths.valuesOf.equal(["h"]));
    assert(m.debugVersions.valuesOf.equal(["D"]) && m.mainSourceFile == "app.d");
    assert(m.buildRequirements.valuesOf.equal(["disallowDeprecations"]));
    assert(parseDubManifest("name \"p\"\ntoolchainRequirements dub=\"*\" gcc=\"*\"\n").hasError);
}

@("build_primitives.dub_manifest.parseDubJsonManifest.forms")
@safe unittest
{
    import std.algorithm.comparison : equal;

    const parsed = parseDubJsonManifest(`{
    "name": "p",
    "version": "1.0.0",
    "-ddoxTool": "ignored",
    "dflags": ["-a"],
    "dflags-linux-ldc": ["-b"],
    "dependencies": { "q": "~>1.0", ":sub": { "path": "sub", "optional": true } },
    "subConfigurations": { "q": "lib" },
    "environments-posix": { "A": "1" },
    "toolchainRequirements": { "frontend": ">=2.100" },
    "configurations": [ { "name": "c", "platforms": ["linux"], "versions": ["V"] } ],
    "buildTypes": { "bt": { "buildOptions": ["optimize"] } },
    "subPackages": [ "path/sub", { "name": "inline", "targetType": "library" } ]
}`, "dub.json");
    assert(parsed.hasValue, parsed.error.text);
    const m = parsed.value;
    assert(m.name == "p" && m.version_ == "1.0.0");
    assert(m.dflags.length == 2);
    foreach (ref d; m.dflags)
        assert(d.platform is null ? d.values == ["-a"] : d.platform == "linux-ldc" && d.values == ["-b"]);
    assert(m.dependencies.length == 2);
    foreach (ref d; m.dependencies)
        assert(d.name == "q" ? d.version_ == "~>1.0" : d.name == ":sub" && d.path == "sub" && d.optional);
    assert(m.subConfigurations[0].dependency == "q" && m.subConfigurations[0].configuration == "lib");
    assert(m.environments[0].values == ["A", "1"] && m.environments[0].platform == "posix");
    assert(m.toolchainRequirements.frontend == ">=2.100");
    assert(m.configurations[0].name == "c" && m.configurations[0].platforms == ["linux"]
        && m.configurations[0].versions.valuesOf.equal(["V"]));
    assert(m.buildTypes[0].name == "bt" && m.buildTypes[0].buildOptions.valuesOf.equal(["optimize"]));
    assert(m.subPackages[0].path == "path/sub" && m.subPackages[1].isInline
        && m.subPackages[1].name == "inline" && m.subPackages[1].targetType == "library");
}

@("build_primitives.dub_manifest.parseDubJsonManifest.rejects")
@safe unittest
{
    const unknown = parseDubJsonManifest("{\n  \"name\": \"p\",\n  \"sourcePath2\": [\"x\"]\n}", "dub.json");
    assert(unknown.hasError);
    assert(unknown.error.text == "dub.json(3:3): Cannot decode a DUB recipe: unknown directive `sourcePath2`",
        unknown.error.text);
    assert(parseDubJsonManifest(`{"name": "p", "targetType-linux": "library"}`).hasError);
    assert(parseDubJsonManifest(`{"name": "p", "dflags": "-O"}`).hasError);
    assert(parseDubJsonManifest(`{"name": "p", "dependencies": {"q": {"version": "*", "dflags": []}}}`)
        .hasError);
    assert(parseDubJsonManifest(`{"name": "p", "subPackages": [{"name": "a", "subPackages": []}]}`)
        .hasError);
    assert(parseDubJsonManifest(`{"name": `).hasError);
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
    tmp.writeFileAt("dub.json", `{"name": "j"}`);
    tmp.writeFileAt("single-json.d", "/+ dub.json: {\"name\": \"sj\"} +/\nvoid main() {}\n");

    assert(readDubManifest(tmp.dir.buildPath("dub.sdl")).value.name == "p");
    assert(readDubManifest(tmp.dir.buildPath("single.d")).value.name == "s");
    assert(readDubManifest(tmp.dir.buildPath("dub.json")).value.name == "j");
    assert(readDubManifest(tmp.dir.buildPath("single-json.d")).value.name == "sj");
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

version (unittest)
{
    /// Every recipe in this repository — `dub.sdl` files and the recipes
    /// single-file packages embed — with its path and text.
    private string[2][] repositoryRecipes()
    {
        import std.algorithm.searching : endsWith;
        import std.file : exists, readText;
        import std.path : buildNormalizedPath, dirName;
        import std.string : lineSplitter;
        import sparkles.build_primitives.git_env : runGit;
        import sparkles.wired.sdl : locateEmbeddedRecipe;

        const root = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");
        const listed = runGit(["ls-files", "*dub.sdl", "*.d"], root);
        string[2][] recipes;
        if (listed.status != 0)
            return recipes;
        foreach (file; listed.output.lineSplitter)
        {
            const path = root.buildNormalizedPath(file);
            if (!path.exists)
                continue;
            const text = path.readText;
            if (path.endsWith(".d"))
            {
                const embedded = locateEmbeddedRecipe(text);
                if (!embedded.found || embedded.isJson)
                    continue;
            }
            recipes ~= [path, text];
        }
        return recipes;
    }

    /// The recipe's document: its own, or the one a `.d` host embeds.
    private auto parseRecipe(string path, string text)
    {
        import core.lifetime : move;
        import std.algorithm.searching : endsWith;
        import sparkles.wired.sdl : parseEmbeddedSdlDocument, parseSdlDocument, sdlDubRecipe;

        if (!path.endsWith(".d"))
            return parseSdlDocument!sdlDubRecipe(text, path);
        auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(text, path);
        return move(embedded.parsed);
    }
}

@("build_primitives.dub_manifest.roundTrip.format")
@system unittest
{
    import sparkles.test_runner.skip : skipTest;
    import sparkles.wired.sdl : fromSDL, parseSdlDocument, SdlString, toSDL, writeSdlDocument;

    // The canonical writer is a formatter: what it writes parses to the same
    // tree, and writing that again changes nothing. Typed, `toSDL` of a
    // decoded recipe decodes to the same value, and is stable.
    const recipes = repositoryRecipes();
    if (recipes.length == 0)
        return skipTest("not a git checkout");
    foreach (recipe; recipes)
    {
        auto parsed = parseRecipe(recipe[0], recipe[1]);
        assert(parsed.hasValue, parsed.error.text);

        SdlString once, twice;
        assert(!writeSdlDocument(parsed.document, once).hasError, recipe[0]);
        auto formatted = parseSdlDocument!sdlDubRecipe(once[]);
        assert(formatted.hasValue, recipe[0] ~ ": " ~ formatted.error.text);
        assert(!writeSdlDocument(formatted.document, twice).hasError);
        assert(once[] == twice[], recipe[0] ~ ": the formatter is not idempotent");

        const value = fromSDL!DubManifest(parsed.document.root);
        assert(value.hasValue, value.error.text);
        const encoded = toSDL(value.value);
        assert(encoded.hasValue, recipe[0] ~ ": " ~ encoded.error.text);
        const decoded = parseDubManifest(encoded.value[]);
        assert(decoded.hasValue, recipe[0] ~ ": " ~ decoded.error.text);
        assert(decoded.value == value.value, recipe[0] ~ ": toSDL does not round-trip");
        assert(toSDL(decoded.value).value[] == encoded.value[], recipe[0]);
    }
}

@("build_primitives.dub_manifest.roundTrip.lossless")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.experimental.allocator.mallocator : Mallocator;
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.wired.sdl : fromSDL, sdlDubRecipe, sdlEditor, updateSDL;

    // The lossless editor writes back exactly the bytes it read: with no
    // edit, and with the unchanged decoded value. A changed value decodes as
    // the change, and keeps every comment outside what it removed.
    const recipes = repositoryRecipes();
    if (recipes.length == 0)
        return skipTest("not a git checkout");
    size_t changed;
    foreach (recipe; recipes)
    {
        const host = recipe[1];
        auto parsed = parseRecipe(recipe[0], host);
        assert(parsed.hasValue, parsed.error.text);
        const decoded = fromSDL!DubManifest(parsed.document.root);
        assert(decoded.hasValue, decoded.error.text);

        string writeBack(scope void delegate(ref typeof(sdlEditor!sdlDubRecipe(parsed.document, host)))
            edit)
        {
            auto editor = sdlEditor!sdlDubRecipe(parsed.document, host);
            edit(editor);
            UniqueBuffer!char output;
            Mallocator allocator;
            const written = editor.write(output, allocator);
            assert(!written.hasError, recipe[0] ~ ": " ~ written.error.text);
            return output[].idup;
        }

        assert(writeBack((ref editor) {}) == host, recipe[0]);
        DubManifest same = cast() decoded.value;
        assert(writeBack((ref editor) => updateSDL(editor, parsed.document.root, same)) == host,
            recipe[0] ~ ": writing back the unchanged value edited it");

        // Where the comment-only lines directly above `start` begin: the
        // editor removes them with the node they describe.
        size_t attachedStart(size_t start)
        {
            import std.string : strip;

            for (;;)
            {
                size_t line = start;
                while (line > 0 && host[line - 1] != '\n')
                    line--;
                if (line == 0)
                    return start;
                size_t above = line - 1;
                while (above > 0 && host[above - 1] != '\n')
                    above--;
                const text = host[above .. line - 1].strip;
                bool commentOnly;
                foreach (comment; parsed.document.comments)
                    commentOnly |= text.length && comment.span.sliceOf(host).strip == text;
                if (!commentOnly)
                    return start;
                start = above;
            }
        }

        // The first configuration removed and a dependency inserted first:
        // a positional pairing would rewrite every element after them.
        DubManifest other = cast() decoded.value;
        other.description = "changed by the round-trip test";
        other.dependencies = DubDependency("sparkles:probe", version_: "*") ~ other.dependencies;
        size_t removedStart = size_t.max, removedEnd;
        const(char)[][] keptConfigurations;
        if (other.configurations.length)
        {
            other.configurations = other.configurations[1 .. $];
            foreach (node; parsed.document.root.byChild)
                if (node.qualifiedName.localName == "configuration")
                {
                    if (removedStart == size_t.max)
                    {
                        removedStart = attachedStart(node.extent.startOffset);
                        removedEnd = node.extent.endOffset;
                    }
                    else
                        keptConfigurations ~= node.extent.sliceOf(host);
                }
        }
        const output = writeBack((ref editor) => updateSDL(editor, parsed.document.root, other));
        auto reparsed = parseRecipe(recipe[0], output);
        assert(reparsed.hasValue, recipe[0] ~ ": " ~ reparsed.error.text);
        const back = fromSDL!DubManifest(reparsed.document.root);
        assert(back.hasValue && back.value == other, recipe[0] ~ ": the change did not round-trip");
        foreach (comment; parsed.document.comments)
            if (comment.span.startOffset < removedStart || comment.span.startOffset >= removedEnd)
                assert(output.canFind(comment.span.sliceOf(host)), recipe[0] ~ ": lost a comment");
        // Every other configuration keeps its bytes (S20).
        foreach (kept; keptConfigurations)
            assert(output.canFind(kept), recipe[0] ~ ": rewrote an unchanged configuration");
        changed++;
    }
    assert(changed > 100);
}

@("build_primitives.dub_manifest.readDubManifest.everyRegistryRecipe")
@system unittest
{
    import std.algorithm.searching : any, canFind;
    import std.file : SpanMode, dirEntries, exists;
    import std.path : baseName, buildPath;
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;

    // The registry packages the DUB locks pin, as the dev shell provides
    // them: each recipe, SDL or JSON, decodes strictly.
    const sources = environment.get("SPARKLES_DUB_SOURCES");
    if (sources is null)
        return skipTest("SPARKLES_DUB_SOURCES is not set");
    const packages = sources.buildPath(".dub", "packages");
    assert(packages.exists, packages);

    size_t recipes;
    foreach (entry; dirEntries(packages, SpanMode.depth, followSymlink: false))
    {
        const name = entry.name.baseName;
        if (name != "dub.sdl" && name != "dub.json")
            continue;
        // Only a package's own recipe: not the test fixtures it ships.
        if (["/test/", "/tests/", "/examples/"].any!(segment => entry.name.canFind(segment)))
            continue;
        const manifest = readDubManifest(entry.name);
        assert(manifest.hasValue, manifest.error.text);
        ++recipes;
    }
    assert(recipes >= 8);
}
