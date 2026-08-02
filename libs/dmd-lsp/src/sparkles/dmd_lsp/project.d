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

    /// The subpackage the settings were described for (`:name` form), empty
    /// when the root package described cleanly. Set by the none-target /
    /// sourceless-root fallback (`PRJ7`).
    string subpackage;

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
        auto res = execute(argv, null, Config.stderrPassThrough);

        // One retry, because a failure here is not always a property of the
        // project: the pinned dmd fork declares the same `preGenerateCommand`
        // in each of its four subpackages, all writing one shared
        // `generated/dub-gen/config` under `~/.dub/packages`. Two of them
        // running close enough together race on it — "Failed to remove file
        // …: No such file or directory" — and dub exits 2 for the whole
        // describe. Reproducible with plain concurrent `dub describe` calls,
        // outside any of our code. A root that genuinely has nothing to
        // describe fails the retry too and falls through unchanged.
        if (res.status != 0)
            res = execute(argv, null, Config.stderrPassThrough);

        if (res.status != 0)
        {
            // A root package with `targetType "none"` (dmd) or without any
            // sources (a monorepo umbrella) has no describable target — dub
            // exits nonzero (or asserts). The file still belongs to one of
            // the root's subpackages; find it (`PRJ7`).
            auto scanned = describeOwningSubpackage(proj, startPath, query,
                text("`dub describe` failed (exit ", res.status, ") in ", proj.root));
            if (scanned.usable)
                return scanned;

            // A `sourceLibrary` has no target for dub to describe either, and
            // unlike a none-target root it owns the file outright, so the scan
            // above had nothing to find. Its *unittest* configuration is
            // buildable — that is what `dub test` builds — and carries the same
            // import paths. Tried last, so a none-target root never reaches it:
            // dub asserts rather than exits when asked for a configuration a
            // recipe does not declare. Only when the caller expressed no
            // preference of its own (`PRJ3`).
            if (query.config.length == 0 && query.buildType.length == 0)
            {
                auto asTest = argv ~ ["--config=unittest", "--build=unittest"];
                const test = execute(asTest, null, Config.stderrPassThrough);
                if (test.status == 0)
                {
                    proj.analyzer = parseDubBuildSettings(lastNonBlankLine(test.output));
                    return proj; // no `error` set ⇒ usable
                }
            }
            return scanned;
        }
        proj.analyzer = parseDubBuildSettings(lastNonBlankLine(res.output));
    }
    catch (Exception e)
        proj.error = "cannot run `dub describe`: " ~ e.msg;

    return proj;
}

/**
The none-target-root fallback: enumerate the root recipe's subpackage
$(B names) (names only — settings still come from `dub describe`, `PRJ2`),
describe each as `dub describe --root=… :name` (the `:name` form resolves
through the root package; `name:sub` would consult dub's global registry and
can land in a different checkout), and pick the one whose described
`sourceFiles` contain `filePath`. Import paths cannot discriminate — sibling
subpackages routinely share them.
*/
private DubProject describeOwningSubpackage(DubProject proj, string filePath,
    DubQuery query, string rootError) @safe
{
    import std.algorithm.sorting : sort;
    import std.path : absolutePath, buildNormalizedPath;

    const names = subpackageNames(proj.recipe);
    if (!names.length)
    {
        proj.error = rootError;
        return proj;
    }

    const wanted = filePath.absolutePath.buildNormalizedPath;

    // Path-referenced subpackages whose directory prefixes the file are the
    // cheapest likely owners; try them first, then the rest in declaration
    // order. (For a path-ref sub the file usually finds that recipe directly
    // via PRJ1 — this fallback matters mostly for inline subpackages.)
    auto ordered = names.dup;
    ordered.sort!((a, b) => pathAffinity(a, wanted) > pathAffinity(b, wanted));

    string[] tried;
    foreach (cand; ordered)
    {
        auto sub = describeSubpackage(proj, cand.name, query);
        tried ~= cand.name;
        if (!sub.usable)
            continue;
        if (ownsFile(sub, wanted))
            return sub;
    }

    import std.array : join;

    proj.error = rootError ~ "; no subpackage owns " ~ wanted
        ~ " (tried :" ~ tried.join(", :") ~ ")";
    return proj;
}

/// One subpackage described via the full JSON (which carries both the build
/// settings and the ownership evidence in one call).
private DubProject describeSubpackage(const DubProject root, string name,
    DubQuery query) @safe
{
    import std.conv : text;
    import std.process : Config, execute;

    DubProject sub;
    sub.recipe = root.recipe;
    sub.root = root.root;
    sub.query = query;
    sub.subpackage = name;

    auto argv = ["dub", "describe", "--root=" ~ root.root, ":" ~ name];
    if (query.config.length)
        argv ~= "--config=" ~ query.config;
    if (query.buildType.length)
        argv ~= "--build=" ~ query.buildType;
    if (query.compiler.length)
        argv ~= "--compiler=" ~ query.compiler;

    try
    {
        const res = execute(argv, null, Config.stderrPassThrough);
        if (res.status != 0)
        {
            sub.error = text("`dub describe :", name, "` failed (exit ",
                res.status, ") in ", root.root);
            return sub;
        }
        parseDescribeJson(res.output, sub);
    }
    catch (Exception e)
        sub.error = text("cannot run `dub describe :", name, "`: ", e.msg);
    return sub;
}

/// Extracts the root target's build settings + source files from a full
/// `dub describe` JSON document.
private void parseDescribeJson(const(char)[] output, ref DubProject sub) @safe
{
    import std.json : JSONValue, parseJSON;

    // dub may print resolution chatter before the JSON document.
    const at = firstIndexOf(output, '{');
    if (at < 0)
    {
        sub.error = "`dub describe` printed no JSON document";
        return;
    }
    JSONValue doc = parseJSON(output[at .. $]);

    const rootName = doc["rootPackage"].str;
    foreach (t; (() @trusted => doc["targets"].array)())
    {
        if (t["rootPackage"].str != rootName)
            continue;
        auto bs = t["buildSettings"];

        static string[] strings(JSONValue v, string key) @safe
        {
            string[] items;
            if (auto member = key in v)
                foreach (e; (() @trusted => member.array)())
                    items ~= e.str;
            return items;
        }

        sub.analyzer.importPaths = strings(bs, "importPaths");
        sub.analyzer.stringImportPaths = strings(bs, "stringImportPaths");
        sub.analyzer.versionIds = strings(bs, "versions");
        sub.analyzer.debugIds = strings(bs, "debugVersions");
        sub.analyzer.dflags = strings(bs, "dflags");
        _subFiles[subFilesKey(sub)] = strings(bs, "sourceFiles");
        return;
    }
    sub.error = "`dub describe` JSON has no root target";
}

/// Whether the described subpackage's source files include `wanted`
/// (normalized absolute path) — the only reliable ownership test.
private bool ownsFile(const DubProject sub, string wanted) @safe
{
    import std.path : buildNormalizedPath;

    if (auto files = subFilesKey(sub) in _subFiles)
        foreach (f; *files)
            if (f.buildNormalizedPath == wanted)
                return true;
    return false;
}

private string subFilesKey(const DubProject sub) @safe pure
    => cacheKey(sub.recipe, sub.subpackage, sub.query);

private string[][string] _subFiles;

/// A declared subpackage: its name and, for the path-reference form, the
/// referenced directory (empty for inline blocks).
private struct SubpackageRef
{
    string name;
    string dir;
}

/// Affinity of a candidate to the file: path-ref subs whose directory
/// prefixes the file win; everything else ties at zero.
private ptrdiff_t pathAffinity(const SubpackageRef cand, string wanted) @safe
{
    import std.algorithm.searching : startsWith;

    return cand.dir.length && wanted.startsWith(cand.dir)
        ? cast(ptrdiff_t) cand.dir.length : 0;
}

/**
The subpackage $(B names) a recipe declares — the one piece `dub describe`
cannot report (there is no subpackage listing in its `--data` vocabulary, and
`dub list` only covers globally registered checkouts). Both `dub.sdl` forms
are handled — inline `subPackage { name "x" … }` blocks and path references
`subPackage "libs/x"` (whose real name comes from the referenced directory's
own recipe) — plus `dub.json`'s `subPackages` array of strings or objects.
Settings never come from here (`PRJ2`).
*/
private SubpackageRef[] subpackageNames(string recipePath) @safe
{
    import std.algorithm.searching : endsWith;
    import std.file : exists, readText;
    import std.path : buildNormalizedPath, buildPath, dirName;

    SubpackageRef[] refs;
    string text;
    try
        text = readText(recipePath);
    catch (Exception)
        return refs;
    const dir = recipePath.dirName;

    if (recipePath.endsWith(".json"))
    {
        import std.json : JSONType, parseJSON;

        try
        {
            auto doc = parseJSON(text);
            if (auto subs = "subPackages" in doc)
                foreach (e; (() @trusted => subs.array)())
                {
                    if (e.type == JSONType.string)
                        refs ~= pathSubpackage(dir, e.str);
                    else if (auto n = "name" in e)
                        refs ~= SubpackageRef(n.str);
                }
        }
        catch (Exception)
        {
        }
        return refs;
    }

    // dub.sdl: line-oriented scan; recipes are simple enough that brace
    // tracking per subPackage block suffices.
    import std.algorithm.iteration : splitter;
    import std.string : strip, stripLeft;

    bool inBlock;
    int depth;
    foreach (rawLine; text.splitter('\n'))
    {
        const line = rawLine.strip;
        if (inBlock)
        {
            import std.algorithm.searching : startsWith;

            if (line.startsWith("name") && depth == 1)
            {
                const q = quotedValue(line["name".length .. $]);
                if (q.length)
                    refs ~= SubpackageRef(q.idup);
            }
            foreach (c; line)
            {
                if (c == '{')
                    depth++;
                else if (c == '}')
                    depth--;
            }
            if (depth <= 0)
                inBlock = false;
            continue;
        }
        import std.algorithm.searching : startsWith;

        if (!line.startsWith("subPackage"))
            continue;
        const rest = line["subPackage".length .. $].stripLeft;
        if (rest.startsWith("{") || rest.length == 0)
        {
            inBlock = true;
            depth = 1;
            continue;
        }
        const q = quotedValue(rest);
        if (q.length)
            refs ~= pathSubpackage(dir, q.idup);
    }
    return refs;
}

/// A path-reference subpackage: its name is the referenced directory's own
/// recipe `name`, falling back to the directory's base name.
private SubpackageRef pathSubpackage(string rootDir, string refPath) @safe
{
    import std.file : exists, isDir, readText;
    import std.path : baseName, buildNormalizedPath, buildPath;

    const dir = rootDir.buildPath(refPath).buildNormalizedPath;
    string name = dir.baseName;
    foreach (recipeName; ["dub.sdl", "dub.json"])
    {
        const rp = dir.buildPath(recipeName);
        if (!rp.exists)
            continue;
        try
        {
            import std.algorithm.iteration : splitter;
            import std.algorithm.searching : startsWith;
            import std.string : strip;

            if (recipeName == "dub.json")
            {
                import std.json : parseJSON;

                if (auto n = "name" in parseJSON(readText(rp)))
                    name = n.str;
            }
            else
                foreach (rawLine; readText(rp).splitter('\n'))
                {
                    const line = rawLine.strip;
                    if (line.startsWith("name"))
                    {
                        const q = quotedValue(line["name".length .. $]);
                        if (q.length)
                        {
                            name = q.idup;
                            break;
                        }
                    }
                }
        }
        catch (Exception)
        {
        }
        break;
    }
    return SubpackageRef(name, dir ~ "/");
}

/// The first double-quoted value in `s`, or empty.
private const(char)[] quotedValue(const(char)[] s) @safe pure
{
    const open = firstIndexOf(s, '"');
    if (open < 0)
        return null;
    const close = firstIndexOf(s[open + 1 .. $], '"');
    if (close < 0)
        return null;
    return s[open + 1 .. open + 1 + close];
}

private ptrdiff_t firstIndexOf(const(char)[] s, char c) @safe pure nothrow @nogc
{
    foreach (i, ch; s)
        if (ch == c)
            return i;
    return -1;
}

/**
`describeDubProject`, memoized per recipe and query (`PRJ8`).

The cache is thread-local and lives for the process: recipes do not change
under a batch run, and an interactive consumer that watches them calls
`clearDubProjectCache` when one does.
*/
DubProject dubProjectFor(string startPath, DubQuery query = DubQuery.init) @safe
{
    import std.path : absolutePath, buildNormalizedPath;

    const recipe = findDubRecipe(startPath);
    if (!recipe.length)
        return DubProject.init;

    // The subpackage fallback resolves ownership per FILE, so the memo key
    // must include the resolved subpackage: a per-recipe key would let the
    // first file under a none-target root poison its siblings (`PRJ8`).
    // Cheap pre-check: a cached result (root or subpackage) that already
    // owns/covers this path answers without shelling out.
    const rootKey = cacheKey(recipe, "", query);
    if (auto hit = rootKey in _cache)
        if (hit.usable || !hit.found)
            return *hit;
    const wanted = startPath.absolutePath.buildNormalizedPath;
    foreach (key, ref cached; _cache)
        if (cached.usable && cached.recipe == recipe && cached.subpackage.length
            && cached.query == query && ownsFile(cached, wanted))
            return cached;

    auto proj = describeDubProject(startPath, query);
    _cache[cacheKey(recipe, proj.subpackage, query)] = proj;
    if (!proj.subpackage.length)
        _cache[rootKey] = proj;
    return proj;
}

/// Drops every memoized project (a recipe changed, or a test wants a fresh
/// process view).
void clearDubProjectCache() @safe
{
    _cache = null;
    _subFiles = null;
}

private DubProject[string] _cache;

private string cacheKey(scope const(char)[] recipe, scope const(char)[] subpackage,
    in DubQuery q) @safe pure
    => recipe.idup ~ "\0" ~ subpackage ~ "\0" ~ q.config ~ "\0" ~ q.buildType
        ~ "\0" ~ q.compiler;

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
@system unittest
{
    import std.file : exists;

    enum here = __FILE_FULL_PATH__;
    if (!here.exists)
        skipOrThrow("the source tree is not present at " ~ here);
    if (!onPath("dub"))
        skipOrThrow("dub is not on PATH");

    DubProject first, again, other;
    // The cache clears belong inside the same critical section as the
    // queries: a clear from a concurrently running dub test would otherwise
    // land between these two lookups, turning the second into the very
    // concurrent `dub describe` this lock exists to prevent.
    synchronized (dubTestSync)
    {
        clearDubProjectCache();
        first = dubProjectFor(here);
        again = dubProjectFor(here);
        // A different query is a different cache entry, not a stale hit.
        other = dubProjectFor(here, DubQuery(buildType: "unittest"));
    }
    assert(first.usable, first.error);
    assert(first.recipe == again.recipe);
    assert(first.analyzer.versionIds == again.analyzer.versionIds);
    assert(other.query.buildType == "unittest");

    synchronized (dubTestSync)
    {
        clearDubProjectCache();
        assert(dubProjectFor("/nonexistent/file.d").found == false);
    }
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

// -- fallback tests ----------------------------------------------------------

version (unittest)
{
    /// Concurrent `dub` child processes contend on dub's own lock files and
    /// fail transiently under the parallel test runner — every dub-invoking
    /// test serializes on this.
    private __gshared Object dubTestSync;

    shared static this()
    {
        dubTestSync = new Object;
    }

    /// A scratch dub project on disk; removed on scope exit.
    private struct TempProject
    {
        string root;

        static TempProject create(string name) @system
        {
            import std.conv : to;
            import std.file : mkdirRecurse, tempDir;
            import std.path : buildPath;
            import std.process : thisProcessID;

            TempProject t;
            t.root = tempDir.buildPath(
                "sparkles-dmd-lsp-" ~ name ~ "-" ~ thisProcessID.to!string);
            mkdirRecurse(t.root);
            return t;
        }

        void put(string rel, string content) @system
        {
            import std.file : mkdirRecurse, write;
            import std.path : buildPath, dirName;

            const path = root.buildPath(rel);
            mkdirRecurse(path.dirName);
            write(path, content);
        }

        void cleanup() @system
        {
            import std.file : rmdirRecurse;

            try
                rmdirRecurse(root);
            catch (Exception)
            {
            }
        }
    }

    private void requireDub() @system
    {
        import std.process : execute;

        import sparkles.test_runner.skip : skipTest;

        try
        {
            if (execute(["dub", "--version"]).status == 0)
                return;
        }
        catch (Exception)
        {
        }
        skipTest("dub not on PATH");
    }
}

@("project.fallback.noneTargetRootInlineSubpackage")
@system unittest
{
    import std.algorithm.searching : canFind, endsWith;
    import std.path : buildPath;

    requireDub();
    auto t = TempProject.create("none-root");
    scope (exit) t.cleanup();

    // The dmd shape: an explicitly none-target root with an inline
    // subpackage (dub describe on the root fails; the file belongs to the
    // subpackage, whose sources live under the root directory itself).
    t.put("dub.sdl",
        "name \"umbrella\"\ntargetType \"none\"\n"
        ~ "subPackage {\n    name \"core\"\n    targetType \"library\"\n"
        ~ "    sourcePaths \"src\"\n    importPaths \"src\"\n}\n");
    t.put("src/core_mod.d", "module core_mod;\nint x;\n");

    const file = t.root.buildPath("src", "core_mod.d");
    DubProject proj;
    synchronized (dubTestSync)
    {
        clearDubProjectCache();
        scope (exit) clearDubProjectCache();
        proj = dubProjectFor(file);
    }
    assert(proj.found);
    assert(proj.usable, proj.error);
    assert(proj.subpackage == "core", proj.subpackage);
    bool hasSrc;
    foreach (ip; proj.analyzer.importPaths)
        if (ip.endsWith("src") || ip.endsWith("src/"))
            hasSrc = true;
    assert(hasSrc, "importPaths missing src");
}

@("project.fallback.sourcelessRootNoOwner")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.path : buildPath;

    requireDub();
    auto t = TempProject.create("bare-root");
    scope (exit) t.cleanup();

    // The monorepo-umbrella shape: a root with only path subpackages and no
    // sources of its own. A stray file directly under the root belongs to no
    // subpackage: the fallback must fail with the candidates named, never
    // crash (PRJ7). A file inside the subpackage never reaches the fallback
    // at all - the innermost recipe wins (PRJ1).
    t.put("dub.sdl", "name \"mono\"\nsubPackage \"libs/thing\"\n");
    t.put("libs/thing/dub.sdl",
        "name \"thing\"\ntargetType \"library\"\n"
        ~ "sourcePaths \"src\"\nimportPaths \"src\"\n");
    t.put("libs/thing/src/thing_mod.d", "module thing_mod;\nint y;\n");
    t.put("stray.d", "module stray;\n");

    DubProject inner, stray;
    synchronized (dubTestSync)
    {
        clearDubProjectCache();
        scope (exit) clearDubProjectCache();
        inner = dubProjectFor(t.root.buildPath("libs", "thing", "src", "thing_mod.d"));
        stray = dubProjectFor(t.root.buildPath("stray.d"));
    }
    assert(inner.usable, inner.error);
    assert(inner.subpackage.length == 0); // its own recipe, no fallback

    assert(stray.found);
    assert(!stray.usable);
    assert(stray.error.canFind(":thing"), stray.error);
}

@("project.subpackageNames.recipeForms")
@system unittest
{
    auto t = TempProject.create("names");
    scope (exit) t.cleanup();

    t.put("dub.sdl",
        "name \"m\"\n"
        ~ "subPackage \"libs/alpha\"\n"
        ~ "subPackage {\n    name \"beta\"\n    targetType \"library\"\n}\n");
    t.put("libs/alpha/dub.sdl", "name \"alpha-real\"\n");

    import std.path : buildPath;

    const refs = subpackageNames(t.root.buildPath("dub.sdl"));
    assert(refs.length == 2);
    assert(refs[0].name == "alpha-real"); // path ref: name from its recipe
    assert(refs[0].dir.length);
    assert(refs[1].name == "beta"); // inline block
    assert(refs[1].dir.length == 0);

    t.put("dub.json",
        `{"name":"m","subPackages":["libs/alpha",{"name":"gamma"}]}`);
    const jrefs = subpackageNames(t.root.buildPath("dub.json"));
    assert(jrefs.length == 2);
    assert(jrefs[0].name == "alpha-real");
    assert(jrefs[1].name == "gamma");
}
