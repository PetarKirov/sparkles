/**
Hidden source edges (build-graph SPEC BGR8, decision D15): a package that
compiles or imports another package's files through `importPaths`,
`sourcePaths`, `sourceFiles`, `stringImportPaths`, `cImportPaths` or
`cSourcePaths` without a `dependency` on it.

Such a reach is invisible to package selection and keeps the build graph
from sharing the reached package's variants, so every one is reported, with
the recipe line, in every configuration it occurs in. There is no exception.
*/
module sparkles.build_primitives.resolve.hidden_edges;

import std.algorithm.searching : canFind, startsWith;
import std.conv : text;
import std.path : buildNormalizedPath, isAbsolute;

import sparkles.build_primitives.resolve.driver : ResolveDriver;
import sparkles.build_primitives.resolve.project : Package;
import sparkles.build_primitives.resolve.recipe : SettingsTemplate;

/// A package and the directory it owns.
struct PackageLocation
{
    string name;      /// the full package name
    string directory; /// absolute, normalized
}

/// One reach into another package without a dependency on it.
struct HiddenEdge
{
    string package_;      /// the package that reaches
    string recipe;        /// its recipe
    size_t line;          /// the directive's line; 0 when the recipe is JSON
    string configuration; /// the configuration it reaches in; null for the top level
    string directive;     /// `importPaths`, …
    string value;         /// the value as written
    string reached;       /// the package reached

    /// `recipe(line): <package> reaches <reached> through <directive> "<value>" …`
    void toString(W)(ref W w) const
    {
        import std.format : formattedWrite;

        w.formattedWrite!"%s(%s): `%s` reaches `%s` through `%s \"%s\"`%s without a dependency on it"(
            recipe, line, package_, reached, directive, value,
            configuration.length ? text(" in configuration `", configuration, "`") : "");
    }
}

/// The directives through which a package reads files.
enum string[] reachingDirectives = ["importPaths", "sourcePaths", "sourceFiles",
    "stringImportPaths", "cImportPaths", "cSourcePaths"];

/**
The hidden edges of `p` among the packages `all` (each owning its directory,
the most deeply nested owner winning). A value naming `$PACKAGE_DIR` is read
relative to `p`; a value naming any other variable is skipped, since it names
no tree location this check can know.
*/
HiddenEdge[] hiddenEdges(const Package p, const PackageLocation[] all, ResolveDriver driver) @safe
{
    const lines = DirectiveLines(p.recipe, driver);
    const top = p.settings.dependencies.keys;
    if (p.configurations.length == 0)
        return hiddenIn(p, p.settings, null, top, all, lines);

    HiddenEdge[] edges;
    foreach (ref c; p.configurations)
    {
        // `dub test`'s configuration reaches what the one it copies does,
        // which is reported at its own recipe lines.
        if (c.copiedFrom.length)
            continue;
        const dependencies = top ~ c.settings.dependencies.keys;
        // The top level's reaches count in each configuration, once.
        foreach (edge; hiddenIn(p, p.settings, null, dependencies, all, lines))
            if (!edges.canFind(edge))
                edges ~= edge;
        edges ~= hiddenIn(p, c.settings, c.name, dependencies, all, lines);
    }
    return edges;
}

private HiddenEdge[] hiddenIn(const Package p, const ref SettingsTemplate declaration,
    string configuration, const string[] dependencies, const PackageLocation[] all,
    ref const DirectiveLines lines) @safe
{
    HiddenEdge[] edges;
    static foreach (directive; reachingDirectives)
        foreach (specifier, values; __traits(getMember, declaration, directive))
            foreach (value; values)
            {
                const path = locate(value, p.directory);
                if (path is null)
                    continue;
                const owner = ownerOf(path, all);
                // An inline subpackage shares its base's directory: a reach
                // into it is a reach into its own.
                if (owner is null || owner.name == p.name || owner.directory == p.directory
                    || dependencies.canFind(owner.name))
                    continue;
                edges ~= HiddenEdge(p.name, p.recipe,
                    lines.of(directive, value, configuration, inlineName(p)),
                    configuration, directive, value, owner.name);
            }
    return edges;
}

// The name of `p` within its base recipe when it is an inline subpackage
// (stated in the same recipe file), else null.
private string inlineName(const Package p) @safe pure
{
    import std.string : lastIndexOf;

    if (p.base is null || p.base is p || p.recipe != p.base.recipe)
        return null;
    return p.name[p.name.lastIndexOf(':') + 1 .. $];
}

// The absolute path a value names, or null when it names a variable other
// than the package's own directory.
private string locate(string value, string directory) @safe pure
{
    import std.array : replace;

    auto expanded = value.replace("${PACKAGE_DIR}", directory).replace("$PACKAGE_DIR", directory);
    if (expanded.canFind('$'))
        return null;
    return expanded.isAbsolute ? buildNormalizedPath(expanded) : buildNormalizedPath(directory, expanded);
}

// The package owning `path`: the one with the longest directory containing
// it, or null.
private const(PackageLocation)* ownerOf(string path, return scope const PackageLocation[] all)
    @safe pure nothrow
{
    const(PackageLocation)* owner;
    size_t longest;
    foreach (ref location; all)
    {
        const d = location.directory;
        const inside = path == d || (path.startsWith(d) && path.length > d.length && path[d.length] == '/');
        if (inside && d.length > longest)
        {
            owner = &location;
            longest = d.length;
        }
    }
    return owner;
}

// The line of each directive occurrence in a recipe: from the SDL document,
// including inline subpackage blocks, or, for JSON, the first line naming the
// value after the directive's key.
private struct DirectiveLines
{
    private static struct Occurrence
    {
        string subPackage;
        string directive;
        string configuration;
        string[] values;
        size_t line;
    }

    private Occurrence[] occurrences;
    private string json;

    this(string recipe, ResolveDriver driver) @safe
    {
        import sparkles.wired.sdl : SdlNode, SdlScalarKind, parseSdlDocument, sdlDubRecipe;

        string source;
        if (!driver.readText(recipe, source))
            return;
        if (recipe.length >= 5 && recipe[$ - 5 .. $] == ".json")
        {
            json = source;
            return;
        }
        if (!(recipe.length >= 4 && recipe[$ - 4 .. $] == ".sdl"))
            return;
        auto parsed = parseSdlDocument!sdlDubRecipe(source, recipe);
        if (parsed.hasError)
            return;

        static string firstValue(scope SdlNode node) @safe
        {
            foreach (v; node.byValue)
                if (v.kind == SdlScalarKind.string_)
                    return v.stringValue.idup;
            return null;
        }

        void collect(scope SdlNode node, string subPackage, string configuration) @safe
        {
            foreach (child; node.byChild)
            {
                if (child.qualifiedName.namespace_.length)
                    continue;
                const name = child.qualifiedName.localName.idup;
                if (name == "configuration")
                {
                    collect(child, subPackage, firstValue(child));
                    continue;
                }
                if (name == "subPackage" && configuration is null && subPackage is null)
                {
                    string inline;
                    foreach (grandchild; child.byChild)
                        if (grandchild.qualifiedName.localName == "name")
                            inline = firstValue(grandchild);
                    if (inline.length)
                        collect(child, inline, null);
                    continue;
                }
                if (!reachingDirectives.canFind(name))
                    continue;
                string[] values;
                foreach (v; child.byValue)
                    if (v.kind == SdlScalarKind.string_)
                        values ~= v.stringValue.idup;
                occurrences ~= Occurrence(subPackage, name, configuration, values,
                    parsed.document.position(child.nameSpan.startOffset).line);
            }
        }

        collect(parsed.document.root, null, null);
    }

    /// The line of `value` under `directive` in `configuration` of the
    /// recipe's package (`subPackage` null) or of its inline subpackage.
    size_t of(string directive, string value, string configuration, string subPackage) const @safe pure
    {
        if (json.length)
            return jsonLine(directive, value);
        foreach (ref o; occurrences)
            if (o.subPackage == subPackage && o.directive == directive && o.configuration == configuration
                && o.values.canFind(value))
                return o.line;
        return 0;
    }

    private size_t jsonLine(string directive, string value) const @safe pure
    {
        import std.algorithm.searching : count;
        import std.string : indexOf;

        const key = json.indexOf(text("\"", directive));
        if (key < 0)
            return 0;
        const at = json[key .. $].indexOf(text("\"", value, "\""));
        return at < 0 ? 0 : json[0 .. key + at].count('\n') + 1;
    }
}

@("build_primitives.resolve.hidden_edges.hiddenEdges.reportsUndeclaredReaches")
@safe unittest
{
    import sparkles.build_primitives.resolve.driver : MemoryDriver;
    import sparkles.build_primitives.resolve.project : loadProject;

    auto driver = new MemoryDriver([
        "/r/dub.sdl": "name \"r\"\nsubPackage \"a\"\nsubPackage \"b\"\nsubPackage \"other\"\n",
        "/r/a/dub.sdl": `name "a"
importPaths "../other/src"
configuration "lib" {
}
configuration "unittest" {
    sourcePaths "$PACKAGE_DIR/../b/src"
}
`,
        "/r/a/source/a.d": "",
        "/r/b/dub.sdl": `name "b"
dependency "r:other" path=".."
importPaths "../other/src" "src"
`,
        "/r/b/src/b.d": "",
        "/r/other/dub.sdl": "name \"other\"\n",
        "/r/other/src/o.d": "",
    ]);
    const all = [PackageLocation("r:a", "/r/a"), PackageLocation("r:b", "/r/b"),
        PackageLocation("r:other", "/r/other")];

    auto a = loadProject("/r", ":a", driver, null);
    const edges = hiddenEdges(a.root, all, driver);
    assert(edges.length == 2, text(edges));
    assert(edges[0] == HiddenEdge("r:a", "/r/a/dub.sdl", 2, null, "importPaths", "../other/src", "r:other"),
        text(edges[0]));
    assert(edges[1] == HiddenEdge("r:a", "/r/a/dub.sdl", 6, "unittest", "sourcePaths", "$PACKAGE_DIR/../b/src",
        "r:b"), text(edges[1]));
    assert(text(edges[0]) == "/r/a/dub.sdl(2): `r:a` reaches `r:other` through `importPaths \"../other/src\"` "
        ~ "without a dependency on it");

    // A declared dependency makes the same reach visible.
    auto b = loadProject("/r", ":b", driver, null);
    assert(hiddenEdges(b.root, all, driver).length == 0);
}

@("build_primitives.resolve.hidden_edges.hiddenEdges.inlineAndJson")
@safe unittest
{
    import sparkles.build_primitives.resolve.driver : MemoryDriver;
    import sparkles.build_primitives.resolve.project : loadProject;

    auto driver = new MemoryDriver([
        "/r/dub.sdl": `name "r"
subPackage {
    name "in"
    targetType "sourceLibrary"
    importPaths "other/src"
}
subPackage "other"
subPackage "j"
`,
        "/r/other/dub.sdl": "name \"other\"\n",
        "/r/j/dub.json": "{\n  \"name\": \"j\",\n  \"importPaths\": [\n    \"../other/src\"\n  ]\n}\n",
    ]);
    const all = [PackageLocation("r", "/r"), PackageLocation("r:other", "/r/other"),
        PackageLocation("r:j", "/r/j")];
    auto inline = loadProject("/r", ":in", driver, null);
    const inlineEdges = hiddenEdges(inline.root, all, driver);
    assert(inlineEdges.length == 1 && inlineEdges[0].line == 5 && inlineEdges[0].reached == "r:other",
        text(inlineEdges));
    auto json = loadProject("/r", ":j", driver, null);
    const jsonEdges = hiddenEdges(json.root, all, driver);
    assert(jsonEdges.length == 1 && jsonEdges[0].line == 4, text(jsonEdges));

    // An inline subpackage's directory is its base's: a reach into the base
    // package's files is no reach into another package.
    driver.files["/r/dub.sdl"] = "name \"r\"\nsubPackage {\n    name \"own\"\n    importPaths \"src\"\n}\n";
    auto own = loadProject("/r", ":own", driver, null);
    assert(hiddenEdges(own.root, [PackageLocation("r", "/r"), PackageLocation("r:own", "/r")], driver)
        .length == 0);
}

@("build_primitives.resolve.hidden_edges.hiddenEdges.testRootCopiesItsConfiguration")
@safe unittest
{
    import sparkles.build_primitives.resolve.driver : MemoryDriver;
    import sparkles.build_primitives.resolve.platform : BuildPlatform;
    import sparkles.build_primitives.resolve.project : addTestRunnerConfiguration, loadProject;

    // `dub test`'s generated configuration copies `unittest`: its reaches are
    // reported once, at the `unittest` configuration's line.
    auto driver = new MemoryDriver([
        "/r/dub.sdl": "name \"r\"\nsubPackage \"a\"\nsubPackage \"other\"\n",
        "/r/a/dub.sdl": "name \"a\"\nconfiguration \"unittest\" {\n    importPaths \"../other/src\"\n}\n",
        "/r/a/source/a.d": "",
        "/r/other/dub.sdl": "name \"other\"\n",
    ]);
    auto a = loadProject("/r", ":a", driver, null);
    addTestRunnerConfiguration(a, BuildPlatform(["linux", "posix"], ["x86_64"], "ldc", "ldc2", 2111, "1.41.0"));
    const edges = hiddenEdges(a.root, [PackageLocation("r:a", "/r/a"), PackageLocation("r:other", "/r/other")],
        driver);
    assert(edges.length == 1 && edges[0].configuration == "unittest" && edges[0].line == 3, text(edges));
}
