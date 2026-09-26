/**
The few facts a dub recipe states that `dub describe` cannot report (`PRJ2`):
the package's own name, the subpackages it declares, and the configurations it
offers — with their dflags, which is how a device configuration is recognized
(`TGT6`).

Settings never come from here: import paths, versions and flags are what dub
resolves, and only `dub describe` knows them. This module answers the
questions that pick $(I which) describe to run — which subpackage owns a file
(`PRJ7`), which configurations a user may select (`PRJ3`), which one is the
device build — without paying a describe per candidate.

All three recipe forms are read: `dub.sdl` (through sparkles:wired's SDLang
reader), `dub.json`, and the recipe a single-file package embeds in its
leading `/+ dub.sdl: … +/` or `/+ dub.json: … +/` comment (`PRJ17`).
*/
module sparkles.dmd_lsp.recipe;

/// A configuration a recipe declares.
struct RecipeConfiguration
{
    string name;     ///
    string[] dflags; /// its own `dflags`, every platform suffix included
}

/// A subpackage a recipe declares: inline (`subPackage { name "x" … }`) or
/// by path (`subPackage "libs/x"`).
struct RecipeSubpackage
{
    /// The inline block's `name`; empty for a path reference, whose name is
    /// the referenced directory's own recipe's.
    string name;
    /// The referenced directory, as written; empty for an inline block.
    string path;
}

/// What a recipe states about itself.
struct DubRecipe
{
    string name;                           ///
    RecipeSubpackage[] subPackages;        ///
    RecipeConfiguration[] configurations;  /// in declaration order

    /// Whether the recipe was read at all.
    bool valid;
}

/**
Reads the recipe at `path`: a `dub.sdl`, a `dub.json`, or a `.d` single-file
package. An unreadable or malformed recipe yields `valid == false` and no
facts — callers fall back exactly as for a recipe that declares nothing.
*/
DubRecipe readDubRecipe(string path) @safe
{
    import std.algorithm.searching : endsWith;
    import std.file : readText;

    string text;
    try
        text = readText(path);
    catch (Exception)
        return DubRecipe.init;

    if (path.endsWith(".d"))
    {
        const embedded = embeddedRecipe(text);
        if (!embedded.found)
            return DubRecipe.init;
        return embedded.isJson ? parseJsonRecipe(embedded.text) : parseSdlRecipe(embedded.text);
    }
    return path.endsWith(".json") ? parseJsonRecipe(text) : parseSdlRecipe(text);
}

/// The configuration names `path`'s recipe declares, in declaration order —
/// the choices a `--config=` selection has (`PRJ3`).
string[] recipeConfigurations(string path) @safe
{
    import std.algorithm.iteration : map;
    import std.array : array;

    return readDubRecipe(path).configurations.map!(c => c.name).array;
}

/// Parses `dub.sdl` text.
DubRecipe parseSdlRecipe(const(char)[] text) @safe
{
    import sparkles.wired.sdl : parseSdlDocument, SdlNode, SdlQualifiedName, SdlScalarKind;

    static string firstString(const SdlNode node) @safe
    {
        if (!node.valueCount)
            return null;
        const value = node.byValue.front;
        return value.kind == SdlScalarKind.string_ ? value.stringValue.idup : null;
    }

    static string[] strings(const SdlNode node) @safe
    {
        string[] items;
        foreach (value; node.byValue)
            if (value.kind == SdlScalarKind.string_)
                items ~= value.stringValue.idup;
        return items;
    }

    DubRecipe recipe;
    auto parsed = parseSdlDocument(text);
    if (parsed.hasError)
        return recipe;
    recipe.valid = true;

    foreach (tag; parsed.document.root.byChild)
    {
        const tagName = tag.qualifiedName;
        if (tagName.namespace_.length)
            continue;
        switch (tagName.localName)
        {
            case "name":
                recipe.name = firstString(tag);
                break;
            case "subPackage":
                if (const path = firstString(tag))
                    recipe.subPackages ~= RecipeSubpackage(path: path);
                else
                    foreach (child; tag.byChild(SdlQualifiedName(null, "name")))
                        recipe.subPackages ~= RecipeSubpackage(name: firstString(child));
                break;
            case "configuration":
                auto config = RecipeConfiguration(firstString(tag));
                if (!config.name.length)
                    break;
                foreach (dflags; tag.byChild(SdlQualifiedName(null, "dflags")))
                    config.dflags ~= strings(dflags);
                recipe.configurations ~= config;
                break;
            default:
                break;
        }
    }
    return recipe;
}

/// Parses `dub.json` text. dub's JSON spells a platform-suffixed setting as
/// its own key (`dflags-ldc`); every `dflags*` key counts.
DubRecipe parseJsonRecipe(const(char)[] text) @safe
{
    import std.algorithm.searching : startsWith;
    import std.json : JSONType, JSONValue, parseJSON;

    static string[] strings(const JSONValue v) @safe
    {
        string[] items;
        if (v.type == JSONType.array)
            foreach (e; (() @trusted => v.array)())
                if (e.type == JSONType.string)
                    items ~= e.str;
        return items;
    }

    DubRecipe recipe;
    JSONValue doc;
    try
        doc = parseJSON(text);
    catch (Exception)
        return recipe;
    if (doc.type != JSONType.object)
        return recipe;
    recipe.valid = true;

    if (auto name = "name" in doc)
        if (name.type == JSONType.string)
            recipe.name = name.str;
    if (auto subs = "subPackages" in doc)
        if (subs.type == JSONType.array)
            foreach (e; (() @trusted => subs.array)())
            {
                if (e.type == JSONType.string)
                    recipe.subPackages ~= RecipeSubpackage(path: e.str);
                else if (e.type == JSONType.object)
                    if (auto n = "name" in e)
                        recipe.subPackages ~= RecipeSubpackage(name: n.str);
            }
    if (auto configs = "configurations" in doc)
        if (configs.type == JSONType.array)
            foreach (c; (() @trusted => configs.array)())
            {
                if (c.type != JSONType.object)
                    continue;
                const n = "name" in c;
                if (n is null || n.type != JSONType.string)
                    continue;
                auto config = RecipeConfiguration(n.str);
                foreach (key, value; (() @trusted => c.object)())
                    if (key == "dflags" || key.startsWith("dflags-"))
                        config.dflags ~= strings(value);
                recipe.configurations ~= config;
            }
    return recipe;
}

private struct Embedded
{
    const(char)[] text;
    bool isJson;
    bool found;
}

/// The recipe inside a single-file package's leading `/+ dub.sdl: … +/`
/// comment (`PRJ17`); empty when there is none.
private Embedded embeddedRecipe(const(char)[] source) @safe pure nothrow @nogc
{
    import std.algorithm.searching : findSplitBefore, startsWith;
    import std.string : stripLeft;

    auto rest = source;
    if (rest.startsWith("#!"))
    {
        foreach (i, c; rest)
            if (c == '\n')
            {
                rest = rest[i + 1 .. $];
                break;
            }
    }
    rest = rest.stripLeft;
    if (!rest.startsWith("/+"))
        return Embedded.init;
    rest = rest[2 .. $].stripLeft;

    bool isJson;
    if (rest.startsWith("dub.sdl:"))
        rest = rest["dub.sdl:".length .. $];
    else if (rest.startsWith("dub.json:"))
    {
        rest = rest["dub.json:".length .. $];
        isJson = true;
    }
    else
        return Embedded.init;

    if (auto split = rest.findSplitBefore("+/"))
        return Embedded(split[0], isJson, found: true);
    return Embedded.init;
}

@("dmd_lsp.recipe.parseSdlRecipe.namesSubpackagesConfigurations")
@safe unittest
{
    const r = parseSdlRecipe(`name "m"
description "a \"quoted\" one"
// A comment, and a continued line.
dflags "-preview=in" \
    "-preview=dip1000"
subPackage "libs/alpha"
subPackage {
    name "beta"
    targetType "library"
}
configuration "library" {
    targetType "library"
}
configuration "gpu" {
    dflags "-O" "-mdcompute-targets=vulkan-130" platform="ldc"
    dflags "-v"
}
`);
    assert(r.valid);
    assert(r.name == "m");
    assert(r.subPackages == [RecipeSubpackage(path: "libs/alpha"), RecipeSubpackage(name: "beta")]);
    assert(r.configurations.length == 2);
    assert(r.configurations[0] == RecipeConfiguration("library"));
    assert(r.configurations[1].name == "gpu");
    assert(r.configurations[1].dflags == ["-O", "-mdcompute-targets=vulkan-130", "-v"]);

    assert(!parseSdlRecipe(`configuration "x" {`).valid);
}

@("dmd_lsp.recipe.parseJsonRecipe.platformSuffixedFlags")
@safe unittest
{
    const r = parseJsonRecipe(`{"name": "p",
        "subPackages": ["libs/alpha", {"name": "gamma"}],
        "configurations": [
            {"name": "library"},
            {"name": "kernels", "dflags-ldc": ["-mdcompute-targets=cuda-800"]}]}`);
    assert(r.valid);
    assert(r.name == "p");
    assert(r.subPackages == [RecipeSubpackage(path: "libs/alpha"), RecipeSubpackage(name: "gamma")]);
    assert(r.configurations == [RecipeConfiguration("library"),
        RecipeConfiguration("kernels", ["-mdcompute-targets=cuda-800"])]);
    assert(!parseJsonRecipe("[1]").valid);
    assert(!parseJsonRecipe("{").valid);
}

@("dmd_lsp.recipe.readDubRecipe.singleFilePackage")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;

    auto tmp = TmpFS.create("sparkles-dmd-lsp-recipe-single");
    tmp.writeFileAt("sdl.d", "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"s\"\n"
        ~ "    configuration \"cli\" {\n    }\n+/\nvoid main() {}\n");
    tmp.writeFileAt("json.d", "/+dub.json: {\"name\": \"j\"} +/\nvoid main() {}\n");
    tmp.writeFileAt("plain.d", "module plain;\n");

    const sdl = readDubRecipe(tmp.dir.buildPath("sdl.d"));
    assert(sdl.name == "s");
    assert(recipeConfigurations(tmp.dir.buildPath("sdl.d")) == ["cli"]);
    assert(readDubRecipe(tmp.dir.buildPath("json.d")).name == "j");
    assert(!readDubRecipe(tmp.dir.buildPath("plain.d")).valid);
    assert(!readDubRecipe(tmp.dir.buildPath("absent.sdl")).valid);
}

@("dmd_lsp.recipe.readDubRecipe.everyRecipeInThisRepository")
@system unittest
{
    import std.file : dirEntries, exists, SpanMode;
    import std.path : buildNormalizedPath, dirName;

    // The reader is SDLang, not dub's own parser: every recipe this
    // repository ships must read, or ownership and device lookups would
    // silently find nothing for that package.
    const root = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");
    const top = readDubRecipe(root.buildNormalizedPath("dub.sdl"));
    assert(top.valid && top.name == "sparkles");
    assert(top.subPackages.length > 40);
    foreach (sub; top.subPackages)
    {
        const path = root.buildNormalizedPath(sub.path, "dub.sdl");
        if (!path.exists)
            continue;
        const recipe = readDubRecipe(path);
        assert(recipe.valid && recipe.name.length, path);
    }
}
