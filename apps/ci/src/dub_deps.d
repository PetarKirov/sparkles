/++
Helpers for reading the repo's `dub.sdl` layout (through the
`sparkles.build_primitives.dub_manifest` schema) and rewriting in-tree
`dependency "<pkg>" version="*"` declarations in markdown examples' recipes.

Split out from `app.d` so the parsers/rewriters are exercised by `dub test`
— the main source file is excluded from the auto-generated test runner.
+/
module dub_deps;

import std.algorithm : canFind, filter, map;
import std.array : array;
import std.path : buildPath, relativePath;
import std.range.primitives : put;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.build_primitives.dub_manifest : embeddedDubRecipe, readDubManifest;
import sparkles.wired.sdl : parseSdlDocument, sdlDubRecipe, SdlNode, SdlQualifiedName,
    SdlScalarKind;

/// Parses sub-package paths from the root `dub.sdl`.
@safe
string[] parseSubPackages(string repoRoot)
{
    auto manifest = readDubManifest(repoRoot.buildPath("dub.sdl"));
    if (manifest.hasError)
        return [];
    return manifest.value.subPackages
        .map!(sub => sub.path)
        .filter!(path => path.length > 0)
        .array;
}

/// Names of all packages — root + subpackages — that live in this repo.
/// Used to decide which `dependency "<name>" version="*"` lines in
/// markdown examples should be redirected to the local working copy
/// during `docs run`/`verify`/`update`, and which owners a glossary entry
/// may name (`--check-glossary`).
@safe
string[] inTreePackageNames(string repoRoot)
{
    auto rootName = repoRoot.buildPath("dub.sdl").readPackageName;
    if (rootName.length == 0)
        return [];

    return rootName ~ repoRoot.parseSubPackages
        .map!(subPath => repoRoot.buildPath(subPath, "dub.sdl").readPackageName)
        .filter!(subName => subName.length > 0)
        .map!(subName => rootName ~ ":" ~ subName)
        .array;
}

@safe
private string readPackageName(string dubSdlPath)
{
    const manifest = readDubManifest(dubSdlPath);
    return manifest.hasValue && manifest.value.name.length ? manifest.value.name : null;
}

/// Writes `code` to `writer`, with the embedded recipe's
/// `dependency "<pkg>" version="*"` declarations for any in-tree package
/// rewritten to `dependency "<pkg>" path="<rel>"`, where `<rel>` is the
/// relative path from `fromDir` (the example's directory) up to the repo
/// root. This lets `docs run`/`verify`/`update` exercise the local working
/// copy of the new code, instead of dub silently resolving against an older
/// registry-published version that may lack the API the example demonstrates.
///
/// Only the `version="*"` attribute is replaced, in place: declarations that
/// pin a specific version or carry other attributes do so deliberately, and
/// everything else in `code` (layout, comments, line endings) is kept.
void writeInTreeDeps(Writer)(ref Writer writer, string code, string repoRoot, string fromDir)
{
    auto names = repoRoot.inTreePackageNames;
    const embedded = embeddedDubRecipe(code);
    if (names.length == 0 || !embedded.found || embedded.isJson)
        return put(writer, code);
    // Rendered at its source position, so spans are offsets into `code`.
    UniqueBuffer!char positioned;
    embedded.toString(positioned);
    auto parsed = parseSdlDocument!sdlDubRecipe(positioned[]);
    if (parsed.hasError)
        return put(writer, code);

    const rel = repoRoot.relativePath(fromDir);
    // The walk is preorder and attributes never nest, so replaced spans
    // arrive in source order and `code` streams through once.
    size_t at;
    void rewrite(scope const SdlNode node)
    {
        foreach (child; node.byChild)
        {
            if (child.qualifiedName == SdlQualifiedName(null, "dependency")
                && child.valueCount == 1 && child.attributeCount == 1)
            {
                const value = child.byValue.front;
                const attribute = child.byAttribute.front;
                if (value.kind == SdlScalarKind.string_ && names.canFind(value.stringValue)
                    && attribute.qualifiedName == SdlQualifiedName(null, "version")
                    && attribute.value.kind == SdlScalarKind.string_
                    && attribute.value.stringValue == "*")
                {
                    put(writer, code[at .. attribute.span.startOffset]);
                    put(writer, `path="`);
                    put(writer, rel);
                    put(writer, `"`);
                    at = attribute.span.endOffset;
                }
            }
            rewrite(child);
        }
    }
    rewrite(parsed.document.root);
    put(writer, code[at .. $]);
}

version (unittest)
{
    import std.file : mkdirRecurse;
    import sparkles.test_utils.tmpfs : TmpFS;

    private string rewritten(string code, string repoRoot, string fromDir) @safe
    {
        import std.array : appender;

        auto writer = appender!string;
        writeInTreeDeps(writer, code, repoRoot, fromDir);
        return writer[];
    }
}

@("dub_deps.writeInTreeDeps.no-in-tree-packages")
@safe
unittest
{
    // When inTreePackageNames returns nothing (no dub.sdl), code passes through unchanged.
    auto tmp = TmpFS.create();
    const root = tmp.dir();

    const code = "/+ dub.sdl:\n    dependency \"sparkles\" version=\"*\"\n+/\n";
    assert(rewritten(code, root, root) == code);
}

@("dub_deps.writeInTreeDeps.rewrites-only-in-tree")
@safe
unittest
{
    // Build a minimal repo layout:
    //   <root>/dub.sdl                          (name "sparkles", two subPackages)
    //   <root>/libs/core-cli/dub.sdl            (name "core-cli")
    //   <root>/libs/test-utils/dub.sdl          (name "test-utils")
    //   <root>/examples/                        (fromDir — example lives here)
    auto tmp = TmpFS.create();
    const root = tmp.dir();

    tmp.writeFileAt("dub.sdl",
        "name \"sparkles\"\n"
        ~ "subPackage \"libs/core-cli\"\n"
        ~ "subPackage \"libs/test-utils\"\n");
    // `writeFileAt` creates the parents, so the sub-package directories come
    // into being with the recipes that make them sub-packages.
    tmp.writeFileAt("libs/core-cli/dub.sdl", "name \"core-cli\"\n");
    tmp.writeFileAt("libs/test-utils/dub.sdl", "name \"test-utils\"\n");

    // `examples/` holds no file — it exists only to be `fromDir`, the
    // directory the rewritten `path=` is made relative to.
    const fromDir = buildPath(root, "examples");
    mkdirRecurse(fromDir);
    // relativePath("<root>", "<root>/examples") == ".."
    const code =
        "#!/usr/bin/env dub\n/+ dub.sdl:\n"
        ~ "    name \"demo\"\n"
        ~ "    dependency \"sparkles\" version=\"*\"\n"
        ~ "    dependency \"sparkles:core-cli\"   version=\"*\" // spaced\n"
        ~ "    // dependency \"sparkles:test-utils\" version=\"*\"\n"
        ~ "    dependency \"other\" version=\"*\"\n"
        ~ "    dependency \"sparkles\" version=\"~>1.0\"\n"
        ~ "    dependency \"sparkles:core-cli\" version=\"*\" optional=true\n"
        ~ "    configuration \"tests\" {\n"
        ~ "        dependency \"sparkles:test-utils\" version=\"*\"\n"
        ~ "    }\n"
        ~ "+/\n"
        ~ "enum s = `dependency \"sparkles\" version=\"*\"`;\n";

    // Only in-tree `version="*"` declarations change, in place; the comment,
    // the pinned and optional ones, and the D code after the recipe do not.
    const expected =
        "#!/usr/bin/env dub\n/+ dub.sdl:\n"
        ~ "    name \"demo\"\n"
        ~ "    dependency \"sparkles\" path=\"..\"\n"
        ~ "    dependency \"sparkles:core-cli\"   path=\"..\" // spaced\n"
        ~ "    // dependency \"sparkles:test-utils\" version=\"*\"\n"
        ~ "    dependency \"other\" version=\"*\"\n"
        ~ "    dependency \"sparkles\" version=\"~>1.0\"\n"
        ~ "    dependency \"sparkles:core-cli\" version=\"*\" optional=true\n"
        ~ "    configuration \"tests\" {\n"
        ~ "        dependency \"sparkles:test-utils\" path=\"..\"\n"
        ~ "    }\n"
        ~ "+/\n"
        ~ "enum s = `dependency \"sparkles\" version=\"*\"`;\n";

    assert(rewritten(code, root, fromDir) == expected);
}

@("dub_deps.writeInTreeDeps.preserves-crlf")
@safe
unittest
{
    auto tmp = TmpFS.create();
    const root = tmp.dir();
    tmp.writeFileAt("dub.sdl", "name \"sparkles\"\n");

    const code = "/+ dub.sdl:\r\n    dependency \"sparkles\" version=\"*\"\r\n+/\r\nimport sparkles;\r\n";
    const expected = "/+ dub.sdl:\r\n    dependency \"sparkles\" path=\".\"\r\n+/\r\nimport sparkles;\r\n";
    assert(rewritten(code, root, root) == expected);
    // Code without a recipe, or with a malformed one, passes through.
    assert(rewritten("dependency \"sparkles\" version=\"*\"\n", root, root)
        == "dependency \"sparkles\" version=\"*\"\n");
    assert(rewritten("/+ dub.sdl:\n    dependency \"sparkles\" version=\"*\" {\n+/\n", root, root)
        == "/+ dub.sdl:\n    dependency \"sparkles\" version=\"*\" {\n+/\n");
}

@("dub_deps.readPackageName")
@safe
unittest
{
    auto tmp = TmpFS.create();
    const root = tmp.dir();

    // Missing file returns null
    assert(readPackageName(buildPath(root, "missing.sdl")) is null);

    // The recipe's `name`, wherever it sits; a `name` inside a block is not it
    const sdlPath = tmp.writeFileAt("dub.sdl",
        "// header comment\n"
        ~ "description \"a package\"\n"
        ~ "subPackage {\n    name \"inline\"\n}\n"
        ~ "name \"sparkles\"\n");
    assert(readPackageName(sdlPath) == "sparkles");

    // Two names are ambiguous, not first-one-wins
    const twoNames = tmp.writeFileAt("two.sdl", "name \"a\"\nname \"b\"\n");
    assert(readPackageName(twoNames) is null);

    // dub.sdl with no `name` field returns null
    const noNamePath = tmp.writeFileAt("no-name.sdl", "description \"missing name\"\n");
    assert(readPackageName(noNamePath) is null);
}

@("dub_deps.inTreePackageNames")
@safe
unittest
{
    import std.conv : to;

    // Two fixtures in one test, so neither may take the default `__FUNCTION__`
    // prefix — they would name the same directory.
    auto tmp = TmpFS.create("ci-in-tree-names");
    const root = tmp.dir();

    tmp.writeFileAt("dub.sdl",
        "name \"sparkles\"\n"
        ~ "subPackage \"libs/core-cli\"\n"
        ~ "subPackage \"libs/test-utils\"\n"
        ~ "subPackage \"libs/broken\"\n");
    tmp.writeFileAt("libs/core-cli/dub.sdl", "name \"core-cli\"\n");
    tmp.writeFileAt("libs/test-utils/dub.sdl", "name \"test-utils\"\n");
    tmp.ensureSubdir("libs/broken"); // listed but has no dub.sdl

    auto names = inTreePackageNames(root);
    assert(names == ["sparkles", "sparkles:core-cli", "sparkles:test-utils"],
        "unexpected names: " ~ names.to!string);

    // No root dub.sdl → empty
    auto emptyTmp = TmpFS.create("ci-in-tree-empty");
    assert(inTreePackageNames(emptyTmp.dir()).length == 0);
}
