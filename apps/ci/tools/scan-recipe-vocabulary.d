#!/usr/bin/env dub
/+ dub.sdl:
    name "scan_recipe_vocabulary"
    targetPath "build"
    dependency "sparkles:build-primitives" path="../../.."
    dependency "sparkles:wired" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
The recipe vocabulary the build graph must support (build-graph SPEC BGR2):
every directive, attribute, form and variable reference used by the recipes in
scope, with the recipes that use each, as the Markdown table of build-graph
`testing.md`'s "The recipe vocabulary".

The recipes in scope are:
$(LIST
    * the root `dub.sdl` and every sub-package it lists, recursively, inline
        `subPackage` blocks included;
    * every package `nix/dub-lock.json` and `nix/ci-dub-lock.json` pin, read
        from the flake's `dub-sources` output, with their sub-packages;
    * the single-file examples `ci --example-files` runs (the globs of
        `standaloneExampleGlobs` in `apps/ci/src/app.d`);
    * the single-file programs in the `d` fences of tracked Markdown files,
        which `ci --verify` runs.
)

SDL is parsed with sparkles:wired's `sdlDubRecipe` profile, which accepts what
DUB's own parser does; JSON with `std.json`. A JSON key is reported under its
SDL name (`dependencies` as `dependency`), and a platform suffix
(`dflags-linux-ldc`) as the base directive plus a platform specifier, so both
forms meet in one row.

Run from the repository root:
---
dub run --single apps/ci/tools/scan-recipe-vocabulary.d -- [--dub-sources <dir>]
---
`<dir>` defaults to `$SPARKLES_DUB_SOURCES` (the dev shell sets it), else to
`nix build .#dub-sources`'s output. Exits non-zero if a recipe fails to parse.
*/
module scan_recipe_vocabulary;

import std.algorithm : all, any, canFind, count, endsWith, filter, map, sort, startsWith;
import std.array : array, join, split;
import std.conv : text;
import std.file : exists, isDir, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, dirName;
import std.process : environment, execute;
import std.range : take;
import std.stdio : stderr, writeln;
import std.string : indexOf, lineSplitter, strip, stripLeft;

import sparkles.build_primitives.dub_manifest : embeddedDubRecipe;
import sparkles.wired.sdl : SdlNode, SdlScalarKind, parseSdlDocument, sdlDubRecipe;

/// Where a recipe comes from; the table groups its users by class.
enum RecipeClass
{
    inRepo,
    registry,
    example,
    markdown,
}

immutable string[RecipeClass.max + 1] className = [
    "in-repo", "registry", "single-file example", "Markdown example",
];

struct Recipe
{
    string id;
    RecipeClass cls;
}

/// Row → the ids of the recipes that use it.
bool[string][string] uses;
/// Recipe id → its class.
RecipeClass[string] recipeClass;
string[] failures;

/// Recipe id → the name the table shows.
string[string] displayName;

void note(string row, in Recipe r)
{
    uses[row][r.id] = true;
}

/// A recipe named `name`, identified by `forcedId` when given: single-file
/// recipes are identified by their file, as their names repeat.
Recipe register(string name, RecipeClass cls, string forcedId)
{
    const r = Recipe(forcedId.length ? forcedId : name, cls);
    recipeClass[r.id] = cls;
    displayName[r.id] = name;
    return r;
}

/// Configuration names DUB treats specially.
immutable specialConfigurations = ["unittest"];

// ---------------------------------------------------------------------------
// The vocabulary shared by both formats

/// JSON keys and their SDL directive names.
immutable string[string] jsonToSdl = [
    "dependencies": "dependency",
    "configurations": "configuration",
    "subPackages": "subPackage",
    "buildTypes": "buildType",
    "subConfigurations": "subConfiguration",
];

/// Directives whose values are paths or file names, where DUB expands globs.
immutable fileListDirectives = [
    "sourceFiles", "excludedSourceFiles", "sourcePaths", "importPaths",
    "cImportPaths", "stringImportPaths", "copyFiles", "extraDependencyFiles",
    "mainSourceFile",
];

/// Directives whose values are themselves vocabulary.
immutable valueDirectives = [
    "targetType", "buildOptions", "buildRequirements", "platforms",
];

/// The variables DUB itself defines in build settings (`$<NAME>_PACKAGE_DIR`
/// is matched as a pattern).
immutable dubVariables = [
    "PACKAGE_DIR", "ROOT_PACKAGE_DIR", "ARCH", "PLATFORM", "PLATFORM_POSIX",
    "BUILD_TYPE", "DUB", "DUB_EXE", "DC", "DC_BASE",
];

bool isBuildSetting(string name) => !["name", "description", "authors",
    "copyright", "license", "homepage", "version", "dependency", "configuration",
    "subPackage", "buildType", "subConfiguration", "toolchainRequirements",
    "targetName", "targetPath", "workingDirectory", "systemDependencies",
    "ddoxFilterArgs", "ddoxTool", "platforms"].canFind(name);

void noteValue(string path, string value, in Recipe r)
{
    // variables: `$NAME`, `${NAME}`, and the `$$` escape
    for (size_t i = 0; i < value.length; ++i)
    {
        if (value[i] != '$')
            continue;
        if (i + 1 < value.length && value[i + 1] == '$')
        {
            note("variable escape `$$`", r);
            ++i;
            continue;
        }
        size_t start = i + 1, end = start;
        const braced = start < value.length && value[start] == '{';
        if (braced)
            end = ++start;
        while (end < value.length && (value[end] == '_'
                || (value[end] >= 'A' && value[end] <= 'Z')
                || (value[end] >= 'a' && value[end] <= 'z')
                || (value[end] >= '0' && value[end] <= '9')))
            ++end;
        if (end == start)
            continue;
        const name = value[start .. end];
        const kind = dubVariables.canFind(name) || name.endsWith("_PACKAGE_DIR")
            ? "DUB variable" : name.startsWith("DUB_") ? "DUB command variable"
            : "environment variable";
        note(text(kind, " `", braced ? "${" ~ name ~ "}" : "$" ~ name, "` (in `", path, "`)"), r);
        i = end - 1;
    }

    const leaf = path.split("/")[$ - 1];
    if (fileListDirectives.canFind(leaf) && value.any!(c => c == '*' || c == '?' || c == '[' || c == '{'))
        note(text("glob in `", path, "`"), r);
    if (valueDirectives.canFind(leaf))
        note(text("`", path, "` value `", value, "`"), r);
}

void notePlatform(string specifier, in Recipe r)
{
    note(text("platform specifier `", specifier, "`"), r);
}

void noteDependencyName(string name, in Recipe r)
{
    if (name.startsWith(":"))
        note("dependency on a sibling by `:name`", r);
    else if (name.canFind(':'))
        note("dependency on a sub-package by `pkg:name`", r);
}

void noteVersionSpec(string spec, in Recipe r)
{
    string form = spec == "*" ? "`*`"
        : spec.startsWith("~>") ? "`~>x`"
        : spec.startsWith("==") ? "`==x`"
        : spec.startsWith(">") || spec.startsWith("<") ? "range `>=x <y`"
        : spec.startsWith("~") ? "branch `~name`"
        : "exact `x.y.z`";
    note(text("dependency version spec ", form), r);
}

// ---------------------------------------------------------------------------
// SDL

string scalarText(T)(T scalar)
{
    final switch (scalar.kind) with (SdlScalarKind)
    {
        case string_: return scalar.stringValue.idup;
        case boolean: return scalar.boolean ? "true" : "false";
        case none, null_, character, integer, longInteger, float_, double_,
            decimal, binary, date, dateTime, zonedDateTime, duration:
            return text("<", scalar.kind, ">");
    }
}

void scanSdlText(scope const(char)[] source, string label, string fallbackId,
    RecipeClass cls, string dir, string forcedId = null)
{
    auto parsed = parseSdlDocument!sdlDubRecipe(source, label);
    if (parsed.hasError)
    {
        failures ~= text(label, ": ", parsed.error.toString);
        return;
    }
    scanSdlRecipe(parsed.document.root, fallbackId, cls, dir, label, null, forcedId);
}

/// The value of a recipe's `name` directive, or `fallback`.
string sdlName(SdlNode recipe, string fallback)
{
    foreach (child; recipe.byChild)
        if (child.qualifiedName.namespace_.length == 0
            && child.qualifiedName.localName == "name" && child.valueCount)
            foreach (v; child.byValue)
                return scalarText(v);
    return fallback;
}

void scanSdlRecipe(SdlNode recipe, string fallbackId, RecipeClass cls, string dir,
    string label, string parent = null, string forcedId = null)
{
    const name = sdlName(recipe, fallbackId);
    const r = register(parent.length ? parent ~ ":" ~ name : name, cls, forcedId);
    foreach (child; recipe.byChild)
        scanSdlNode(child, "", r, dir, label);
}

void scanSdlNode(SdlNode node, string prefix, in Recipe r, string dir, string label)
{
    const qn = node.qualifiedName;
    const tag = qn.namespace_.length ? text(qn.namespace_, ":", qn.localName) : qn.localName.idup;
    const path = prefix ~ tag;

    if (tag == "subPackage" && prefix.length == 0 && node.childCount)
    {
        note("`subPackage` as an inline block", r);
        scanSdlRecipe(node, "?", r.cls, dir, label, r.id);
        return;
    }
    if (tag == "subPackage" && prefix.length == 0)
    {
        note("`subPackage` as a path", r);
        foreach (v; node.byValue)
            scanRecipeDir(buildNormalizedPath(dir, scalarText(v)), r.cls, r.id);
        return;
    }

    note(text("`", path, "`"), r);
    if (node.valueCount == 0 && !node.hasBlock && fileListDirectives.canFind(tag))
        note(text("empty `", path, "`"), r);

    string[] values;
    foreach (v; node.byValue)
        values ~= scalarText(v);

    foreach (attribute; node.byAttribute)
    {
        const aqn = attribute.qualifiedName;
        const aname = aqn.namespace_.length ? text(aqn.namespace_, ":", aqn.localName) : aqn.localName.idup;
        const avalue = scalarText(attribute.value);
        note(text("`", path, "@", aname, "`"), r);
        if (aname == "platform")
        {
            note("platform as an SDL `platform` attribute", r);
            notePlatform(avalue, r);
        }
        if (tag == "dependency" && aname == "version")
            noteVersionSpec(avalue, r);
        noteValue(text(path, "@", aname), avalue, r);
    }

    if (tag == "dependency" && values.length)
        noteDependencyName(values[0], r);
    if (prefix.length == 0 && tag == "buildType" && values.length)
        note(text("`buildType` named `", values[0], "`"), r);
    if (prefix.length == 0 && tag == "configuration" && values.length
        && specialConfigurations.canFind(values[0]))
        note(text("`configuration` named `", values[0], "`"), r);
    if (tag == "platforms")
        foreach (v; values)
            notePlatform(v, r);
    foreach (v; values)
        noteValue(path, v, r);

    foreach (child; node.byChild)
        scanSdlNode(child, path ~ "/", r, dir, label);
}

// ---------------------------------------------------------------------------
// JSON

void scanJsonText(string source, string label, string fallbackId, RecipeClass cls, string dir,
    string forcedId = null)
{
    JSONValue json;
    try
        json = parseJSON(source);
    catch (Exception e)
    {
        failures ~= text(label, ": ", e.msg);
        return;
    }
    scanJsonRecipe(json, fallbackId, cls, dir, null, forcedId);
}

void scanJsonRecipe(JSONValue recipe, string fallbackId, RecipeClass cls, string dir,
    string parent = null, string forcedId = null)
{
    const name = "name" in recipe.object ? recipe["name"].str : fallbackId;
    const r = register(parent.length ? parent ~ ":" ~ name : name, cls, forcedId);
    note("recipe as `dub.json`", r);
    foreach (key, value; recipe.object)
        scanJsonKey(key, value, "", r, dir);
}

void scanJsonStrings(JSONValue value, string path, in Recipe r)
{
    if (value.type == JSONType.string)
        noteValue(path, value.str, r);
    else if (value.type == JSONType.array)
        foreach (v; value.array)
            scanJsonStrings(v, path, r);
}

void scanJsonKey(string key, JSONValue value, string prefix, in Recipe r, string dir)
{
    string tag = key;
    if (auto sdl = key in jsonToSdl)
        tag = *sdl;
    else if (key.length > 1 && key[0] != '-' && key.indexOf('-') > 0)
    {
        const dash = key.indexOf('-');
        tag = key[0 .. dash];
        note("platform as a JSON key suffix", r);
        notePlatform(key[dash + 1 .. $], r);
    }
    const path = prefix ~ tag;

    if (tag == "subPackage" && prefix.length == 0)
    {
        foreach (sub; value.array)
        {
            if (sub.type == JSONType.string)
            {
                note("`subPackage` as a path", r);
                scanRecipeDir(buildNormalizedPath(dir, sub.str), r.cls, r.id);
            }
            else
            {
                note("`subPackage` as an inline block", r);
                scanJsonRecipe(sub, "?", r.cls, dir, r.id);
            }
        }
        return;
    }

    note(text("`", path, "`"), r);
    switch (tag)
    {
        case "dependency":
            foreach (dep, spec; value.object)
            {
                noteDependencyName(dep, r);
                if (spec.type == JSONType.string)
                {
                    note(text("`", path, "` as a version string"), r);
                    noteVersionSpec(spec.str, r);
                    continue;
                }
                foreach (attr, v; spec.object)
                {
                    note(text("`", path, "@", attr, "`"), r);
                    if (attr == "version")
                        noteVersionSpec(v.str, r);
                    scanJsonStrings(v, text(path, "@", attr), r);
                }
            }
            break;
        case "configuration":
            foreach (conf; value.array)
                foreach (k, v; conf.object)
                {
                    // the name is the SDL form's value, not a directive
                    if (k == "name")
                    {
                        if (specialConfigurations.canFind(v.str))
                            note(text("`configuration` named `", v.str, "`"), r);
                        continue;
                    }
                    scanJsonKey(k, v, path ~ "/", r, dir);
                }
            break;
        case "buildType":
            foreach (buildTypeName, settings; value.object)
            {
                note(text("`buildType` named `", buildTypeName, "`"), r);
                foreach (k, v; settings.object)
                    scanJsonKey(k, v, path ~ "/", r, dir);
            }
            break;
        case "toolchainRequirements":
        case "subConfiguration":
            foreach (attr, v; value.object)
            {
                if (tag == "toolchainRequirements")
                    note(text("`", path, "@", attr, "`"), r);
                scanJsonStrings(v, path, r);
            }
            break;
        default:
            if (value.type == JSONType.array && value.array.length == 0
                && fileListDirectives.canFind(tag))
                note(text("empty `", path, "`"), r);
            if (tag == "platforms")
                foreach (v; value.array)
                    notePlatform(v.str, r);
            scanJsonStrings(value, path, r);
    }
}

// ---------------------------------------------------------------------------
// Recipe sources

/// Scans the recipe in `dir` (`dub.sdl`, else `dub.json`, else `package.json`).
void scanRecipeDir(string dir, RecipeClass cls, string parent = null)
{
    const fallback = parent.length ? parent ~ ":" ~ dir.baseName : dir.baseName;
    foreach (file; ["dub.sdl", "dub.json", "package.json"])
    {
        const path = buildPath(dir, file);
        if (!exists(path))
            continue;
        // A path sub-package is named `parent:name` by its parent.
        if (file == "dub.sdl")
            scanSdlFileAs(path, parent, cls);
        else
            scanJsonFileAs(path, parent, cls);
        return;
    }
    failures ~= text(dir, ": no recipe");
}

void scanSdlFileAs(string path, string parent, RecipeClass cls)
{
    auto parsed = parseSdlDocument!sdlDubRecipe(readText(path), path);
    if (parsed.hasError)
    {
        failures ~= text(path, ": ", parsed.error.toString);
        return;
    }
    scanSdlRecipe(parsed.document.root, path.dirName.baseName, cls, path.dirName, path, parent);
}

void scanJsonFileAs(string path, string parent, RecipeClass cls)
{
    JSONValue json;
    try
        json = parseJSON(readText(path));
    catch (Exception e)
    {
        failures ~= text(path, ": ", e.msg);
        return;
    }
    scanJsonRecipe(json, path.dirName.baseName, cls, path.dirName, parent);
}

string[] gitLsFiles(string[] pathspecs)
{
    const result = execute(["git", "ls-files", "--"] ~ pathspecs);
    if (result.status != 0)
        throw new Exception("git ls-files failed: " ~ result.output);
    return result.output.lineSplitter.filter!(l => l.length != 0).map!(l => l.idup).array;
}

/// The globs of `standaloneExampleGlobs` in `apps/ci/src/app.d`, read from the
/// source so that the scan follows the list `ci --example-files` runs.
string[] exampleGlobs()
{
    const source = readText("apps/ci/src/app.d");
    const start = source.indexOf("string[] standaloneExampleGlobs()");
    if (start < 0)
        throw new Exception("standaloneExampleGlobs not found in apps/ci/src/app.d");
    const end = start + source[start .. $].indexOf("];");
    string[] globs;
    foreach (line; source[start .. end].lineSplitter)
    {
        const l = line.strip;
        if (l.startsWith(`"`) && l.endsWith(`",`))
            globs ~= l[1 .. $ - 2].idup;
    }
    return globs;
}

void scanSingleFile(scope const(char)[] source, string id, RecipeClass cls, string dir)
{
    const embedded = embeddedDubRecipe(source);
    if (!embedded.found)
        return;
    const label = id;
    if (embedded.isJson)
        scanJsonText(embedded.recipe.idup, label, id, cls, dir, id);
    else
        scanSdlText(embedded.recipe, label, id, cls, dir, id);
}

/// The `d` fences of a Markdown file that hold a single-file program.
void scanMarkdown(string file)
{
    const source = readText(file);
    string fence;
    size_t fenceLine;
    string[] body;
    size_t lineNo;
    foreach (line; source.lineSplitter)
    {
        ++lineNo;
        const t = line.stripLeft;
        if (fence.length == 0)
        {
            foreach (marker; ["```", "~~~"])
            {
                if (!t.startsWith(marker))
                    continue;
                size_t n = 0;
                while (n < t.length && t[n] == marker[0])
                    ++n;
                const info = t[n .. $].strip.split;
                if (info.length && info[0] == "d")
                {
                    fence = t[0 .. n].idup;
                    fenceLine = lineNo;
                    body = null;
                }
                else if (info.length || n >= 3)
                {
                    // another language's fence: skip to its end
                    fence = "-" ~ t[0 .. n].idup;
                }
                break;
            }
            continue;
        }
        const closing = fence[0] == '-' ? fence[1 .. $] : fence;
        if (t.startsWith(closing) && t.strip.all!(c => c == closing[0]))
        {
            if (fence[0] != '-')
                scanSingleFile(body.join("\n"), text(file, ":", fenceLine),
                    RecipeClass.markdown, file.dirName);
            fence = null;
            continue;
        }
        if (fence[0] != '-')
            body ~= line.idup;
    }
}

string dubSources(string[] args)
{
    foreach (i, a; args)
        if (a == "--dub-sources" && i + 1 < args.length)
            return args[i + 1];
    if (auto env = environment.get("SPARKLES_DUB_SOURCES"))
        return env;
    const built = execute(["nix", "build", ".#dub-sources", "--no-link", "--print-out-paths"]);
    if (built.status != 0)
        throw new Exception("nix build .#dub-sources failed: " ~ built.output);
    return built.output.lineSplitter.filter!(l => l.startsWith("/nix/store/")).array[$ - 1].idup;
}

// ---------------------------------------------------------------------------
// The table

string usedBy(in bool[string] ids, size_t[RecipeClass.max + 1] totals)
{
    string[][RecipeClass.max + 1] byClass;
    foreach (id, _; ids)
        byClass[recipeClass[id]] ~= id;
    string[] parts;
    foreach (cls; RecipeClass.min .. RecipeClass.max + 1)
    {
        auto names = byClass[cls].map!shortName.array.sort.array;
        if (!names.length)
            continue;
        if (names.length == totals[cls] && names.length > 4)
            parts ~= text("all ", names.length, " ", className[cls]);
        else if (names.length <= 4)
            parts ~= text(className[cls], ": ", names.map!(n => "`" ~ n ~ "`").join(", "));
        else
            parts ~= text(names.length, " ", className[cls], ": ",
                names.take(3).map!(n => "`" ~ n ~ "`").join(", "), ", …");
    }
    return parts.join("; ");
}

/// A package by its name, an example by its file, a Markdown fence by its
/// file's last two path components and its line.
string shortName(string id)
    => recipeClass[id] == RecipeClass.example ? id.baseName
        : recipeClass[id] == RecipeClass.markdown && id.dirName != "."
            ? buildPath(id.dirName.baseName, id.baseName)
        : recipeClass[id] == RecipeClass.markdown ? id
        : displayName[id];

int main(string[] args)
{
    if (!exists("dub.sdl") || !exists("apps/ci/src/app.d"))
    {
        stderr.writeln("run from the repository root");
        return 2;
    }

    // In-repo: the root recipe and, through its `subPackage` paths, the rest.
    scanSdlFileAs("dub.sdl", null, RecipeClass.inRepo);

    // Registry: every pinned package, from the flake's DUB sources.
    const sources = dubSources(args);
    foreach (lock; ["nix/dub-lock.json", "nix/ci-dub-lock.json"])
        foreach (name, entry; parseJSON(readText(lock))["dependencies"].object)
            scanRecipeDir(buildPath(sources, ".dub", "packages", name,
                entry["version"].str, name), RecipeClass.registry);

    foreach (file; gitLsFiles(exampleGlobs()))
        scanSingleFile(readText(file), file, RecipeClass.example, file.dirName);
    foreach (file; gitLsFiles(["*.md"]))
        scanMarkdown(file);

    size_t[RecipeClass.max + 1] totals;
    foreach (_, cls; recipeClass)
        ++totals[cls];

    writeln("<!-- ", totals[RecipeClass.inRepo], " in-repo, ", totals[RecipeClass.registry],
        " registry, ", totals[RecipeClass.example], " single-file example and ",
        totals[RecipeClass.markdown], " Markdown example recipes -->");
    writeln();
    writeln("| Directive or form | Used by |");
    writeln("| ----------------- | ------- |");
    foreach (row; uses.keys.sort)
        writeln("| ", row.escapePipes, " | ", usedBy(uses[row], totals), " |");

    foreach (f; failures)
        stderr.writeln("error: ", f);
    return failures.length ? 1 : 0;
}

string escapePipes(string s) => s.canFind('|') ? s.split("|").join(`\|`) : s;
