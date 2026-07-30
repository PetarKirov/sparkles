/**
Dub-project context for real-world source files (spec `PRJ*`,
`docs/specs/dmd-lsp/project.md`).

`AnalyzerConfig` says $(B how) to analyze a buffer; for a file that belongs to
a real project the answer lives in that project's build recipe, not in the
file. This module derives it: walk up from the file to the nearest
`dub.sdl`/`dub.json`, ask `dub describe` for the exact build settings of the
selected configuration and build type, and translate the compiler-formatted
flags back into the analyzer's own knobs — `-I` to import paths, `-J` to
string-import paths, `-version=`/`-d-version=` to version identifiers, and so
on. Analyzing `libs/dmd-lsp` itself is the motivating case: its sources only
make sense with `LanguageServer`, `NoBackend`, `MARS` and the frontend's own
`-I`/`-J` paths, all of which dub already knows.

Results are cached per project (`PRJ8`): discovery costs one `dub describe`
(half a second for a project with a git dependency), which a viewer should pay
once per project, never once per file.

Nothing here touches the frontend — it is process plus text — so a consumer
that only wants project context (a viewer deciding what to hand a batch
extractor) pays no analysis cost for it.
*/
module sparkles.dmd_lsp.project;

import sparkles.dmd_lsp.options : AnalyzerConfig;

/// Which view of the project to describe. An empty field means "dub's own
/// default" — the same settings a plain `dub build` would use (`PRJ3`).
struct DubQuery
{
    /// `--config=`: dub's default configuration when empty.
    string config;

    /// `--build=`: dub's default build type (`debug`) when empty.
    string buildType;

    /// `--compiler=`: dub's configured default when empty. Only the flag
    /// $(I spelling) changes with it (`-version=` for dmd, `-d-version=` for
    /// ldc); both spellings are parsed, so leaving this empty is safe.
    string compiler;
}

/// A discovered project and the analysis configuration it implies.
struct DubProject
{
    /// Directory holding the recipe; empty when no project encloses the file.
    string root;

    /// Full path of the recipe (`dub.sdl` or `dub.json`).
    string recipe;

    /// The query that produced `analyzer`.
    DubQuery query;

    /// Import paths, string-import paths, version and debug identifiers and
    /// dflags exactly as dub reports them (`PRJ4`). Left at `.init` when
    /// `error` is set.
    AnalyzerConfig analyzer;

    /// Why `dub describe` failed, empty on success (`PRJ7`).
    string error;

    /// A recipe was found: the file is inside a dub project.
    bool found() const @safe pure nothrow @nogc => recipe.length != 0;

    /// A recipe was found $(I and) described successfully.
    bool usable() const @safe pure nothrow @nogc => found && error.length == 0;

    /**
    `analyzer` plus the frontend-matched druntime/phobos import paths from
    `$SPARKLES_DMD_IMPORT_PATH` (`PRJ6`).

    dub reports the project's own sources and its dependencies; it says
    nothing about the runtime the analysis needs, and the two must not be
    confused — a project path can never substitute for `object.d`.
    */
    AnalyzerConfig withRuntimeImports() const @safe
        => AnalyzerConfig(
            importPaths: analyzer.importPaths ~ AnalyzerConfig().effectiveImportPaths,
            stringImportPaths: analyzer.stringImportPaths.dup,
            versionIds: analyzer.versionIds.dup,
            debugIds: analyzer.debugIds.dup,
            dflags: analyzer.dflags.dup);
}

/**
The nearest enclosing dub recipe, or null.

`startPath` may be a file or a directory and may be relative; the walk starts
at the containing directory and climbs to the filesystem root, so the
$(I innermost) project wins — in a monorepo a file under `libs/base/src`
belongs to `libs/base`, not to the root package (`PRJ1`).
*/
string findDubRecipe(string startPath) @safe
{
    import std.file : exists, isDir;
    import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;

    if (!startPath.length)
        return null;

    auto dir = startPath.absolutePath.buildNormalizedPath;
    if (!(dir.exists && dir.isDir))
        dir = dir.dirName;

    for (;;)
    {
        static immutable recipes = ["dub.sdl", "dub.json"];
        foreach (name; recipes)
        {
            const candidate = dir.buildPath(name);
            if (candidate.exists)
                return candidate;
        }
        const parent = dir.dirName;
        if (parent == dir)
            return null;
        dir = parent;
    }
}

/**
Translates one line of `dub describe --data=…` output — build settings
formatted for a compiler command line — into an `AnalyzerConfig` (`PRJ4`).

Both compiler spellings are accepted, so the caller never has to pin
`--compiler=`. Anything unrecognized becomes a dflag, where
`sparkles.dmd_lsp.init_.applyDflags` picks out the subset the analysis
understands and ignores the rest.
*/
AnalyzerConfig parseDubBuildSettings(scope const(char)[] settings) @safe pure
{
    AnalyzerConfig cfg;
    foreach (token; splitArgs(settings))
    {
        if (const path = valueAfter(token, ["-I"]))
            cfg.importPaths ~= path;
        else if (const path = valueAfter(token, ["-J"]))
            cfg.stringImportPaths ~= path;
        else if (const id = valueAfter(token, ["-version=", "-d-version=", "--d-version="]))
            cfg.versionIds ~= id;
        else if (const id = valueAfter(token, ["-debug=", "-d-debug=", "--d-debug="]))
            cfg.debugIds ~= id;
        else
            cfg.dflags ~= token;
    }
    return cfg;
}

/**
Discovers the project enclosing `startPath` and describes it (`PRJ2`).

A missing recipe is not an error: the returned `DubProject` simply reports
`found == false`, and the caller falls back to its own configuration. A dub
that fails (unresolvable dependencies, an unknown configuration, no dub on
`PATH`) leaves `error` set and `analyzer` empty, so a broken project degrades
to environment-only analysis rather than to no analysis at all (`PRJ7`).
*/
DubProject describeDubProject(string startPath, DubQuery query = DubQuery.init) @safe
{
    import std.conv : text;
    import std.path : dirName;
    import std.process : Config, execute;

    DubProject proj;
    proj.query = query;
    proj.recipe = findDubRecipe(startPath);
    if (!proj.found)
        return proj;
    proj.root = proj.recipe.dirName;

    auto argv = ["dub", "describe", "--root=" ~ proj.root,
        "--data=import-paths,string-import-paths,versions,debug-versions,dflags"];
    if (query.config.length)
        argv ~= "--config=" ~ query.config;
    if (query.buildType.length)
        argv ~= "--build=" ~ query.buildType;
    if (query.compiler.length)
        argv ~= "--compiler=" ~ query.compiler;

    try
    {
        // dub's own progress/diagnostics stay on stderr, where a CLI shows
        // them and a GUI ignores them; only the settings line is captured.
        const res = execute(argv, null, Config.stderrPassThrough);
        if (res.status != 0)
        {
            proj.error = text("`dub describe` failed (exit ", res.status, ") in ", proj.root);
            return proj;
        }
        proj.analyzer = parseDubBuildSettings(lastNonBlankLine(res.output));
    }
    catch (Exception e)
        proj.error = "cannot run `dub describe`: " ~ e.msg;

    return proj;
}

/**
`describeDubProject`, memoized per recipe and query (`PRJ8`).

The cache is thread-local and lives for the process: recipes do not change
under a batch run, and an interactive consumer that watches them calls
`clearDubProjectCache` when one does.
*/
DubProject dubProjectFor(string startPath, DubQuery query = DubQuery.init) @safe
{
    const recipe = findDubRecipe(startPath);
    if (!recipe.length)
        return DubProject.init;

    const key = cacheKey(recipe, query);
    if (auto hit = key in _cache)
        return *hit;

    auto proj = describeDubProject(recipe, query);
    _cache[key] = proj;
    return proj;
}

/// Drops every memoized project (a recipe changed, or a test wants a fresh
/// process view).
void clearDubProjectCache() @safe
{
    _cache = null;
}

private DubProject[string] _cache;

private string cacheKey(scope const(char)[] recipe, in DubQuery q) @safe pure
    => recipe.idup ~ "\0" ~ q.config ~ "\0" ~ q.buildType ~ "\0" ~ q.compiler;

/// The settings line: `dub describe --data=…` prints exactly one, but a
/// dependency resolution can put chatter above it. (No `scope` on the
/// parameter: `splitter` rejects it under dip1000.)
private string lastNonBlankLine(const(char)[] output) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.string : strip;

    string last;
    foreach (line; output.splitter('\n'))
        if (line.strip.length)
            last = line.idup;
    return last;
}

/// The value a token carries for one of `prefixes`, or null when it matches
/// none. A `-I=path` spelling sheds the `=` as well.
private string valueAfter(scope const(char)[] token, scope const(string)[] prefixes) @safe pure
{
    import std.algorithm.searching : startsWith;

    foreach (prefix; prefixes)
    {
        if (token.length <= prefix.length || !token.startsWith(prefix))
            continue;
        auto value = token[prefix.length .. $];
        if (value[0] == '=')
            value = value[1 .. $];
        return value.length ? value.idup : null;
    }
    return null;
}

/// Splits a command line on whitespace, honoring double quotes around paths
/// with spaces (which dub emits verbatim).
private string[] splitArgs(scope const(char)[] line) @safe pure
{
    string[] tokens;
    char[] token;
    bool quoted, pending;

    foreach (c; line)
    {
        if (c == '"')
        {
            quoted = !quoted;
            pending = true;
        }
        else if (!quoted && (c == ' ' || c == '\t' || c == '\r' || c == '\n'))
        {
            if (pending)
                tokens ~= token.idup;
            token.length = 0;
            pending = false;
        }
        else
        {
            token ~= c;
            pending = true;
        }
    }
    if (pending)
        tokens ~= token.idup;
    return tokens;
}

// -- tests -------------------------------------------------------------------

@("dmd_lsp.project.parseDubBuildSettings.dmdSpelling")
@safe pure unittest
{
    const cfg = parseDubBuildSettings(
        "-I/pkg/src/ -I/dep/source/ -J/pkg/views/ -version=Have_pkg -debug=Trace "
        ~ "-preview=in -preview=dip1000");

    assert(cfg.importPaths == ["/pkg/src/", "/dep/source/"], cfg.importPaths.toDebug);
    assert(cfg.stringImportPaths == ["/pkg/views/"]);
    assert(cfg.versionIds == ["Have_pkg"]);
    assert(cfg.debugIds == ["Trace"]);
    assert(cfg.dflags == ["-preview=in", "-preview=dip1000"], cfg.dflags.toDebug);
}

@("dmd_lsp.project.parseDubBuildSettings.ldcSpelling")
@safe pure unittest
{
    // The ldc line for this very package: the version identifiers are the
    // whole point — its sources do not compile without them.
    const cfg = parseDubBuildSettings(
        "-I/pkg/libs/dmd-lsp/src/ -I/cache/dmd/compiler/src/ -J/cache/dmd/compiler/src/dmd/res/ "
        ~ "-d-version=NoBackend -d-version=LanguageServer -d-version=MARS -d-debug=Verbose");

    assert(cfg.importPaths.length == 2);
    assert(cfg.stringImportPaths == ["/cache/dmd/compiler/src/dmd/res/"]);
    assert(cfg.versionIds == ["NoBackend", "LanguageServer", "MARS"]);
    assert(cfg.debugIds == ["Verbose"]);
    assert(cfg.dflags.length == 0);
}

@("dmd_lsp.project.parseDubBuildSettings.quotingAndBlanks")
@safe pure unittest
{
    const cfg = parseDubBuildSettings("   -I\"/two words/src/\"   -I=/eq/src/  ");
    assert(cfg.importPaths == ["/two words/src/", "/eq/src/"], cfg.importPaths.toDebug);
    assert(parseDubBuildSettings("").importPaths.length == 0);
    assert(parseDubBuildSettings("   \n  ").dflags.length == 0);
}

@("dmd_lsp.project.findDubRecipe.walksUpToTheInnermostPackage")
@safe unittest
{
    import std.file : exists;
    import std.path : baseName, dirName, buildPath;

    // This module is itself inside a dub package, three directories below its
    // recipe — the exact shape the walk exists for.
    enum here = __FILE_FULL_PATH__;
    if (!here.exists)
        skipOrThrow("the source tree is not present at " ~ here);

    const recipe = findDubRecipe(here);
    assert(recipe.baseName == "dub.sdl", recipe);
    assert(recipe.dirName.baseName == "dmd-lsp", recipe);

    // A directory start behaves like a file start in the same directory.
    assert(findDubRecipe(here.dirName) == recipe);

    // The walk terminates at the filesystem root instead of spinning, and an
    // empty start is simply "no project".
    assert(findDubRecipe("/nonexistent/deep/path/file.d") is null);
    assert(findDubRecipe("") is null);
}

@("dmd_lsp.project.describeDubProject.thisPackage")
@safe unittest
{
    import std.algorithm.searching : canFind, endsWith;
    import std.file : exists;

    enum here = __FILE_FULL_PATH__;
    if (!here.exists)
        skipOrThrow("the source tree is not present at " ~ here);
    if (!onPath("dub"))
        skipOrThrow("dub is not on PATH");

    const proj = describeDubProject(here);
    assert(proj.found, "no recipe found for " ~ here);
    if (!proj.usable)
        skipOrThrow(proj.error); // an offline/unresolvable checkout, not a defect

    // `sparkles:dmd-lsp` compiles the frontend behind these identifiers; a
    // context that lost them would mis-analyze every file in this package.
    assert(proj.analyzer.versionIds.canFind("LanguageServer"),
        proj.analyzer.versionIds.toDebug);
    assert(proj.analyzer.versionIds.canFind("NoBackend"));
    assert(proj.analyzer.importPaths.canFind!(p => p.endsWith("libs/dmd-lsp/src/")),
        proj.analyzer.importPaths.toDebug);

    // The runtime tail is appended, never substituted for project paths.
    const merged = proj.withRuntimeImports;
    assert(merged.importPaths.length >= proj.analyzer.importPaths.length);
    assert(merged.importPaths[0 .. proj.analyzer.importPaths.length]
        == proj.analyzer.importPaths);
}

@("dmd_lsp.project.dubProjectFor.cachesPerRecipe")
@safe unittest
{
    import std.file : exists;

    enum here = __FILE_FULL_PATH__;
    if (!here.exists)
        skipOrThrow("the source tree is not present at " ~ here);
    if (!onPath("dub"))
        skipOrThrow("dub is not on PATH");

    clearDubProjectCache();
    const first = dubProjectFor(here);
    const again = dubProjectFor(here);
    assert(first.recipe == again.recipe);
    assert(first.analyzer.versionIds == again.analyzer.versionIds);

    // A different query is a different cache entry, not a stale hit.
    const other = dubProjectFor(here, DubQuery(buildType: "unittest"));
    assert(other.query.buildType == "unittest");

    clearDubProjectCache();
    assert(dubProjectFor("/nonexistent/file.d").found == false);
}

version (unittest)
{
    /// Skips when the runner is linked in (the `unittest` configuration),
    /// throws otherwise — the plain `library` build has no runner to skip in.
    private void skipOrThrow(string reason) @safe
    {
        version (Have_sparkles_test_runner)
        {
            import sparkles.test_runner.skip : skipTest;

            skipTest(reason);
        }
        else
            throw new Exception(reason);
    }

    private bool onPath(string tool) @safe
    {
        import std.algorithm.iteration : splitter;
        import std.file : exists;
        import std.path : buildPath;
        import std.process : environment;

        foreach (dir; environment.get("PATH", "").splitter(':'))
            if (dir.length && dir.buildPath(tool).exists)
                return true;
        return false;
    }

    private string toDebug(in string[] values) @safe pure
    {
        import std.conv : to;

        return values.to!string;
    }
}
