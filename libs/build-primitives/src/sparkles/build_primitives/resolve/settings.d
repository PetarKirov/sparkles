/**
Resolved build settings: what one target's compile and link need, as dub's
`BuildSettings` holds them, with dub's merge rules (build-graph SPEC §2).

Each `add…` keeps dub's semantics: lists drop values already present, except
`dflags`, which drop only an immediate repeat, and `lflags` and the command
lists, which keep every value. String import files are unique by base name.

Copied from dub (`dub.compilers.buildsettings`, the option tables of
`dub.compilers.dmd` and `dub.compilers.ldc`, `enforceBuildRequirements`); see
the build-graph decisions on behaviour copied from dub's source.
*/
module sparkles.build_primitives.resolve.settings;

import std.algorithm.searching : canFind, startsWith;

/// A target's kind, as dub names it.
enum TargetType
{
    autodetect,     ///
    none,           ///
    executable,     ///
    library,        ///
    sourceLibrary,  ///
    dynamicLibrary, ///
    staticLibrary,  ///
    object,         ///
}

/// A build option: a flag dub translates per compiler. The values are dub's.
enum BuildOption : uint
{
    none = 0,                     ///
    debugMode = 1 << 0,           ///
    releaseMode = 1 << 1,         ///
    coverage = 1 << 2,            ///
    debugInfo = 1 << 3,           ///
    debugInfoC = 1 << 4,          ///
    alwaysStackFrame = 1 << 5,    ///
    stackStomping = 1 << 6,       ///
    inline = 1 << 7,              ///
    noBoundsCheck = 1 << 8,       ///
    optimize = 1 << 9,            ///
    profile = 1 << 10,            ///
    unittests = 1 << 11,          ///
    verbose = 1 << 12,            ///
    ignoreUnknownPragmas = 1 << 13, ///
    syntaxOnly = 1 << 14,         ///
    warnings = 1 << 15,           ///
    warningsAsErrors = 1 << 16,   ///
    ignoreDeprecations = 1 << 17, ///
    deprecationWarnings = 1 << 18, ///
    deprecationErrors = 1 << 19,  ///
    property = 1 << 20,           ///
    profileGC = 1 << 21,          ///
    pic = 1 << 22,                ///
    betterC = 1 << 23,            ///
    lowmem = 1 << 24,             ///
    coverageCTFE = 1 << 25,       ///
    color = 1 << 26,              ///
}

/// A build requirement, which adjusts the options. The values are dub's.
enum BuildRequirement : uint
{
    none = 0,                     ///
    allowWarnings = 1 << 0,       ///
    silenceWarnings = 1 << 1,     ///
    disallowDeprecations = 1 << 2, ///
    silenceDeprecations = 1 << 3, ///
    disallowInlining = 1 << 4,    ///
    disallowOptimization = 1 << 5, ///
    requireBoundsCheck = 1 << 6,  ///
    requireContracts = 1 << 7,    ///
    relaxProperties = 1 << 8,     ///
    noDefaultFlags = 1 << 9,      ///
}

/// The options dub passes from a dependent down to its dependencies.
enum uint inheritedBuildOptions = BuildOption.debugMode | BuildOption.releaseMode
    | BuildOption.coverage | BuildOption.coverageCTFE | BuildOption.debugInfo
    | BuildOption.debugInfoC | BuildOption.alwaysStackFrame | BuildOption.stackStomping
    | BuildOption.inline | BuildOption.noBoundsCheck | BuildOption.profile
    | BuildOption.ignoreUnknownPragmas | BuildOption.syntaxOnly | BuildOption.warnings
    | BuildOption.warningsAsErrors | BuildOption.ignoreDeprecations
    | BuildOption.deprecationWarnings | BuildOption.deprecationErrors | BuildOption.property
    | BuildOption.profileGC | BuildOption.pic;

/// One target's settings, in dub's field order.
struct BuildSettings
{
    TargetType targetType;   ///
    string targetPath;       ///
    string targetName;       ///
    string workingDirectory; ///
    string mainSourceFile;   ///
    string[] dflags;         ///
    string[] lflags;         ///
    string[] libs;           ///
    string[] frameworks;     ///
    string[] linkerFiles;    ///
    string[] sourceFiles;    ///
    string[] injectSourceFiles;    ///
    string[] copyFiles;            ///
    string[] extraDependencyFiles; ///
    string[] versions;             ///
    string[] debugVersions;        ///
    string[] versionFilters;       ///
    string[] debugVersionFilters;  ///
    string[] importPaths;          ///
    string[] cImportPaths;         ///
    string[] stringImportPaths;    ///
    string[] importFiles;          ///
    string[] stringImportFiles;    ///
    string[] preGenerateCommands;  ///
    string[] postGenerateCommands; ///
    string[] preBuildCommands;     ///
    string[] postBuildCommands;    ///
    string[] preRunCommands;       ///
    string[] postRunCommands;      ///
    string[string] environments;   ///
    string[string] buildEnvironments; ///
    string[string] runEnvironments;   ///
    uint requirements; /// `BuildRequirement` bits
    uint options;      /// `BuildOption` bits

    /// Merges `other` onto these settings, as dub's `BuildSettings.add`.
    ref BuildSettings add(in BuildSettings other) return @safe pure nothrow
    {
        addDFlags(other.dflags);
        addLFlags(other.lflags);
        addLibs(other.libs);
        addFrameworks(other.frameworks);
        addLinkerFiles(other.linkerFiles);
        addSourceFiles(other.sourceFiles);
        addInjectSourceFiles(other.injectSourceFiles);
        addCopyFiles(other.copyFiles);
        addExtraDependencyFiles(other.extraDependencyFiles);
        addVersions(other.versions);
        addDebugVersions(other.debugVersions);
        addVersionFilters(other.versionFilters);
        addDebugVersionFilters(other.debugVersionFilters);
        addImportPaths(other.importPaths);
        addCImportPaths(other.cImportPaths);
        addStringImportPaths(other.stringImportPaths);
        addImportFiles(other.importFiles);
        addStringImportFiles(other.stringImportFiles);
        addPreGenerateCommands(other.preGenerateCommands);
        addPostGenerateCommands(other.postGenerateCommands);
        addPreBuildCommands(other.preBuildCommands);
        addPostBuildCommands(other.postBuildCommands);
        addPreRunCommands(other.preRunCommands);
        addPostRunCommands(other.postRunCommands);
        addEnvironments(environments, other.environments);
        addEnvironments(buildEnvironments, other.buildEnvironments);
        addEnvironments(runEnvironments, other.runEnvironments);
        requirements |= other.requirements;
        options |= other.options;
        return this;
    }

    /// A deep copy.
    BuildSettings dup() const @safe pure nothrow
    {
        BuildSettings copy;
        copy.targetType = targetType;
        copy.targetPath = targetPath;
        copy.targetName = targetName;
        copy.workingDirectory = workingDirectory;
        copy.mainSourceFile = mainSourceFile;
        copy.add(this);
        return copy;
    }

    /// dflags drop only a value equal to the last one (dub's `uniq`).
    void addDFlags(in string[] values...) @safe pure nothrow
    {
        foreach (v; values)
            if (dflags.length == 0 || dflags[$ - 1] != v)
                dflags ~= v;
    }

    void addLFlags(in string[] values...) @safe pure nothrow { lflags ~= values; } ///
    void addLibs(in string[] values...) @safe pure nothrow { addUnique(libs, values); } ///
    void addFrameworks(in string[] values...) @safe pure nothrow { addUnique(frameworks, values); } ///
    void addLinkerFiles(in string[] values...) @safe pure nothrow { addUnique(linkerFiles, values); } ///
    void addSourceFiles(in string[] values...) @safe pure nothrow { addUnique(sourceFiles, values); } ///
    void addInjectSourceFiles(in string[] values...) @safe pure nothrow { addUnique(injectSourceFiles, values); } ///
    void addCopyFiles(in string[] values...) @safe pure nothrow { addUnique(copyFiles, values); } ///
    void addExtraDependencyFiles(in string[] values...) @safe pure nothrow { addUnique(extraDependencyFiles, values); } ///
    void addVersions(in string[] values...) @safe pure nothrow { addUnique(versions, values); } ///
    void addDebugVersions(in string[] values...) @safe pure nothrow { addUnique(debugVersions, values); } ///
    void addVersionFilters(in string[] values...) @safe pure nothrow { addUnique(versionFilters, values); } ///
    void addDebugVersionFilters(in string[] values...) @safe pure nothrow { addUnique(debugVersionFilters, values); } ///
    void addImportPaths(in string[] values...) @safe pure nothrow { addUnique(importPaths, values); } ///
    void addCImportPaths(in string[] values...) @safe pure nothrow { addUnique(cImportPaths, values); } ///
    void addStringImportPaths(in string[] values...) @safe pure nothrow { addUnique(stringImportPaths, values); } ///
    void addImportFiles(in string[] values...) @safe pure nothrow { addUnique(importFiles, values); } ///
    void addPreGenerateCommands(in string[] values...) @safe pure nothrow { preGenerateCommands ~= values; } ///
    void addPostGenerateCommands(in string[] values...) @safe pure nothrow { postGenerateCommands ~= values; } ///
    void addPreBuildCommands(in string[] values...) @safe pure nothrow { preBuildCommands ~= values; } ///
    void addPostBuildCommands(in string[] values...) @safe pure nothrow { postBuildCommands ~= values; } ///
    void addPreRunCommands(in string[] values...) @safe pure nothrow { preRunCommands ~= values; } ///
    void addPostRunCommands(in string[] values...) @safe pure nothrow { postRunCommands ~= values; } ///

    /// Prepends `values` not yet present, keeping their order (dub's `prepend`).
    void prependStringImportPaths(in string[] values...) @safe pure nothrow
    {
        foreach_reverse (v; values)
            if (!stringImportPaths.canFind(v))
                stringImportPaths = v ~ stringImportPaths;
    }

    /// String import files are unique by base name: the first one wins.
    void addStringImportFiles(in string[] values...) @safe pure nothrow
    {
        import std.path : baseName;

        foreach (v; values)
            if (!stringImportFiles.canFind!((a, b) => a.baseName == b.baseName)(v))
                stringImportFiles ~= v;
    }

    /// Removes the source files equal to, or matching the glob of, any of
    /// `patterns` (dub's `removePaths`).
    void removeSourceFiles(in string[] patterns...) @safe pure nothrow
    {
        import std.algorithm.iteration : filter;
        import std.algorithm.searching : any;
        import std.array : array;

        sourceFiles = sourceFiles.filter!(f => !patterns.any!(p => pathMatches(f, p))).array;
    }

    /// Removes `values` from the dflags.
    void removeDFlags(in string[] values...) @safe pure nothrow
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        dflags = dflags.filter!(f => !values.canFind(f)).array;
    }
}

// Appends each value not already present.
private void addUnique(ref string[] list, in string[] values) @safe pure nothrow
{
    foreach (v; values)
        if (!list.canFind(v))
            list ~= v;
}

// Adds the entries whose name is not yet set.
private void addEnvironments(ref string[string] into, in string[string] values) @safe pure nothrow
{
    foreach (name, value; values)
        if (name !in into)
            into[name] = value;
}

/// Whether `path` is `pattern` as written, or matches it as a glob (dub's
/// `pathMatch`, whose `NativePath` comparison is by segments as written).
bool pathMatches(string path, string pattern) @safe pure nothrow
{
    import std.path : globMatch;

    return path == pattern || globMatch(path, pattern);
}

/// A recipe's `buildOptions` value, or `none` for a name dub does not know.
BuildOption buildOptionNamed(scope const(char)[] name) @safe pure nothrow @nogc
{
    static foreach (member; __traits(allMembers, BuildOption))
        if (name == member && member != "none")
            return __traits(getMember, BuildOption, member);
    return BuildOption.none;
}

/// A recipe's `buildRequirements` value, or `none` for a name dub does not know.
BuildRequirement buildRequirementNamed(scope const(char)[] name) @safe pure nothrow @nogc
{
    static foreach (member; __traits(allMembers, BuildRequirement))
        if (name == member && member != "none")
            return __traits(getMember, BuildRequirement, member);
    return BuildRequirement.none;
}

/// A recipe's `targetType` value; `autodetect` for none written.
bool parseTargetType(scope const(char)[] name, out TargetType type) @safe pure nothrow @nogc
{
    if (name.length == 0)
    {
        type = TargetType.autodetect;
        return true;
    }
    static foreach (member; __traits(allMembers, TargetType))
        if (name == member)
        {
            type = __traits(getMember, TargetType, member);
            return true;
        }
    return false;
}

private struct OptionFlags
{
    BuildOption option;
    immutable(string)[] flags;
}

// dub's `dub.compilers.dmd.DMDCompiler.s_options`.
private immutable OptionFlags[] dmdOptions = [
    OptionFlags(BuildOption.debugMode, ["-debug"]),
    OptionFlags(BuildOption.releaseMode, ["-release"]),
    OptionFlags(BuildOption.coverage, ["-cov"]),
    OptionFlags(BuildOption.coverageCTFE, ["-cov=ctfe"]),
    OptionFlags(BuildOption.debugInfo, ["-g"]),
    OptionFlags(BuildOption.debugInfoC, ["-g"]),
    OptionFlags(BuildOption.alwaysStackFrame, ["-gs"]),
    OptionFlags(BuildOption.stackStomping, ["-gx"]),
    OptionFlags(BuildOption.inline, ["-inline"]),
    OptionFlags(BuildOption.noBoundsCheck, ["-noboundscheck"]),
    OptionFlags(BuildOption.optimize, ["-O"]),
    OptionFlags(BuildOption.profile, ["-profile"]),
    OptionFlags(BuildOption.unittests, ["-unittest"]),
    OptionFlags(BuildOption.verbose, ["-v"]),
    OptionFlags(BuildOption.ignoreUnknownPragmas, ["-ignore"]),
    OptionFlags(BuildOption.syntaxOnly, ["-o-"]),
    OptionFlags(BuildOption.warnings, ["-wi"]),
    OptionFlags(BuildOption.warningsAsErrors, ["-w"]),
    OptionFlags(BuildOption.ignoreDeprecations, ["-d"]),
    OptionFlags(BuildOption.deprecationWarnings, ["-dw"]),
    OptionFlags(BuildOption.deprecationErrors, ["-de"]),
    OptionFlags(BuildOption.property, ["-property"]),
    OptionFlags(BuildOption.profileGC, ["-profile=gc"]),
    OptionFlags(BuildOption.betterC, ["-betterC"]),
    OptionFlags(BuildOption.lowmem, ["-lowmem"]),
    OptionFlags(BuildOption.color, ["-color"]),
];

// dub's `dub.compilers.ldc.LDCCompiler.s_options`.
private immutable OptionFlags[] ldcOptions = [
    OptionFlags(BuildOption.debugMode, ["-d-debug"]),
    OptionFlags(BuildOption.releaseMode, ["-release"]),
    OptionFlags(BuildOption.coverage, ["-cov"]),
    OptionFlags(BuildOption.coverageCTFE, ["-cov=ctfe"]),
    OptionFlags(BuildOption.debugInfo, ["-g"]),
    OptionFlags(BuildOption.debugInfoC, ["-gc"]),
    OptionFlags(BuildOption.alwaysStackFrame, ["-disable-fp-elim"]),
    OptionFlags(BuildOption.inline, ["-enable-inlining", "-Hkeep-all-bodies"]),
    OptionFlags(BuildOption.noBoundsCheck, ["-boundscheck=off"]),
    OptionFlags(BuildOption.optimize, ["-O3"]),
    OptionFlags(BuildOption.profile, ["-fdmd-trace-functions"]),
    OptionFlags(BuildOption.unittests, ["-unittest"]),
    OptionFlags(BuildOption.verbose, ["-v"]),
    OptionFlags(BuildOption.ignoreUnknownPragmas, ["-ignore"]),
    OptionFlags(BuildOption.syntaxOnly, ["-o-"]),
    OptionFlags(BuildOption.warnings, ["-wi"]),
    OptionFlags(BuildOption.warningsAsErrors, ["-w"]),
    OptionFlags(BuildOption.ignoreDeprecations, ["-d"]),
    OptionFlags(BuildOption.deprecationWarnings, ["-dw"]),
    OptionFlags(BuildOption.deprecationErrors, ["-de"]),
    OptionFlags(BuildOption.property, ["-property"]),
    OptionFlags(BuildOption.betterC, ["-betterC"]),
    OptionFlags(BuildOption.lowmem, ["-lowmem"]),
    OptionFlags(BuildOption.color, ["-enable-color"]),
];

/**
Moves the dflags that spell a build option, a version or a debug version
into those settings, as dub's `extractBuildOptions` does for `compiler`
(`dmd`, or `ldc`; dub reads every package's own dflags with the DMD table
first, whatever the compiler).
*/
void extractBuildOptions(ref BuildSettings settings, scope const(char)[] compiler) @safe pure nothrow
{
    const ldc = compiler == "ldc";
    const table = ldc ? ldcOptions : dmdOptions;
    const versionPrefix = ldc ? "-d-version=" : "-version=";
    const debugPrefix = ldc ? "-d-debug=" : "-debug=";

    string[] kept;
    nextFlag: foreach (flag; settings.dflags)
    {
        foreach (ref entry; table)
            if (entry.flags.canFind(flag))
            {
                settings.options |= entry.option;
                continue nextFlag;
            }
        if (flag.startsWith(versionPrefix))
            settings.addVersions(flag[versionPrefix.length .. $]);
        else if (flag.startsWith(debugPrefix))
            settings.addDebugVersions(flag[debugPrefix.length .. $]);
        else
            kept ~= flag;
    }
    settings.dflags = kept;
}

/// Adjusts the options to the requirements, as dub's `enforceBuildRequirements`.
void enforceBuildRequirements(ref BuildSettings settings) @safe pure nothrow @nogc
{
    alias O = BuildOption;
    alias R = BuildRequirement;
    const r = settings.requirements;
    settings.options |= O.warningsAsErrors;
    if (r & R.allowWarnings)
        settings.options = (settings.options & ~O.warningsAsErrors) | O.warnings;
    if (r & R.silenceWarnings)
        settings.options &= ~(O.warningsAsErrors | O.warnings);
    if (r & R.disallowDeprecations)
        settings.options = (settings.options & ~(O.ignoreDeprecations | O.deprecationWarnings))
            | O.deprecationErrors;
    if (r & R.silenceDeprecations)
        settings.options = (settings.options & ~(O.deprecationErrors | O.deprecationWarnings))
            | O.ignoreDeprecations;
    if (r & R.disallowInlining)
        settings.options &= ~O.inline;
    if (r & R.disallowOptimization)
        settings.options &= ~O.optimize;
    if (r & R.requireBoundsCheck)
        settings.options &= ~O.noBoundsCheck;
    if (r & R.requireContracts)
        settings.options &= ~O.releaseMode;
    if (r & R.relaxProperties)
        settings.options &= ~O.property;
}

// dub's `abiCriticalPrefixes`.
private immutable string[] abiCriticalPrefixes = [
    "-mattr=", "-mcpu=", "-mtriple=", "-checkaction=", "-boundscheck=", "-fsanitize=",
    "-march=", "-mfpu=", "-mfloat-abi=",
];

/// The dflags dub passes down to every dependency: those that change the ABI.
string[] abiCriticalFlags(const string[] dflags) @safe pure nothrow
{
    import std.algorithm.searching : any;

    string[] critical;
    foreach (string flag; dflags)
        if (abiCriticalPrefixes.any!(p => flag.startsWith(p)))
            critical ~= flag;
    return critical;
}

/// A package name as the `Have_` version spells it: every character that is
/// no D identifier character becomes `_`.
string haveVersion(string packageName) @safe pure nothrow
{
    import std.ascii : isAlphaNum;

    auto result = new char[packageName.length];
    foreach (i, c; packageName)
        result[i] = isAlphaNum(c) || c == '_' ? c : '_';
    return "Have_" ~ (() @trusted => cast(string) result)();
}

/// The names of the options set in `options`, in declaration order.
string[] optionNames(uint options) @safe pure nothrow
{
    string[] names;
    static foreach (member; __traits(allMembers, BuildOption))
        static if (member != "none")
            if (options & __traits(getMember, BuildOption, member))
                names ~= member;
    return names;
}

/// The names of the requirements set in `requirements`, in declaration order.
string[] requirementNames(uint requirements) @safe pure nothrow
{
    string[] names;
    static foreach (member; __traits(allMembers, BuildRequirement))
        static if (member != "none")
            if (requirements & __traits(getMember, BuildRequirement, member))
                names ~= member;
    return names;
}

@("build_primitives.resolve.settings.BuildSettings.addSemantics")
@safe pure nothrow unittest
{
    BuildSettings s;
    s.addDFlags("-a", "-b", "-a", "-a");
    assert(s.dflags == ["-a", "-b", "-a"]);
    s.addVersions("V", "W", "V");
    assert(s.versions == ["V", "W"]);
    s.addLFlags("-l", "-l");
    assert(s.lflags == ["-l", "-l"]);
    s.addStringImportFiles("a/x.txt", "b/y.txt", "c/x.txt");
    assert(s.stringImportFiles == ["a/x.txt", "b/y.txt"]);
    s.addStringImportPaths("p");
    s.prependStringImportPaths("q", "r", "p");
    assert(s.stringImportPaths == ["q", "r", "p"]);
    s.addSourceFiles("src/a.d", "src/b.d", "src/sub/c.d");
    s.removeSourceFiles("src/a.d", "src/sub/*", "./src/b.d");
    // `./src/b.d` names no file as written: dub removes nothing for it.
    assert(s.sourceFiles == ["src/b.d"]);
}

@("build_primitives.resolve.settings.extractBuildOptions.perCompiler")
@safe pure nothrow unittest
{
    BuildSettings dmd;
    dmd.dflags = ["-O", "-g", "-version=X", "-debug=Y", "-preview=in", "-O3"];
    dmd.extractBuildOptions("dmd");
    assert(dmd.options == (BuildOption.optimize | BuildOption.debugInfo));
    assert(dmd.versions == ["X"] && dmd.debugVersions == ["Y"]);
    assert(dmd.dflags == ["-preview=in", "-O3"]);

    BuildSettings ldc;
    ldc.dflags = ["-O3", "-d-version=X", "-version=Z", "-enable-inlining"];
    ldc.extractBuildOptions("ldc");
    assert(ldc.options == (BuildOption.optimize | BuildOption.inline));
    assert(ldc.versions == ["X"] && ldc.dflags == ["-version=Z"]);
}

@("build_primitives.resolve.settings.enforceBuildRequirements.dubRules")
@safe pure nothrow @nogc unittest
{
    BuildSettings s;
    s.requirements = BuildRequirement.disallowDeprecations | BuildRequirement.allowWarnings;
    s.options = BuildOption.deprecationWarnings | BuildOption.inline;
    s.enforceBuildRequirements;
    assert(s.options == (BuildOption.deprecationErrors | BuildOption.warnings | BuildOption.inline));
}

@("build_primitives.resolve.settings.names")
@safe pure nothrow unittest
{
    assert(buildOptionNamed("betterC") == BuildOption.betterC);
    assert(buildOptionNamed("bogus") == BuildOption.none);
    assert(buildRequirementNamed("disallowDeprecations") == BuildRequirement.disallowDeprecations);
    TargetType t;
    assert(parseTargetType("sourceLibrary", t) && t == TargetType.sourceLibrary);
    assert(parseTargetType("", t) && t == TargetType.autodetect);
    assert(!parseTargetType("app", t));
    assert(haveVersion("sparkles:base") == "Have_sparkles_base");
    assert(haveVersion("raylib-d") == "Have_raylib_d");
    assert(abiCriticalFlags(["-w", "-mcpu=native", "-checkaction=context", "-O"])
        == ["-mcpu=native", "-checkaction=context"]);
    assert(optionNames(BuildOption.unittests | BuildOption.debugMode) == ["debugMode", "unittests"]);
}
