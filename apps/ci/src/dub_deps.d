/++
Helpers for reading the repo's `dub.sdl` layout and rewriting in-tree
`dependency "<pkg>" version="*"` lines in markdown example code blocks.

Split out from `app.d` so the parsers/rewriters are exercised by `dub test`
— the main source file is excluded from the auto-generated test runner.
+/
module dub_deps;

import std.algorithm : canFind, filter, map;
import std.array : array, join;
import std.conv : text;
import std.file : exists, readText;
import std.path : buildPath, relativePath;
import std.string : endsWith, indexOf, lineSplitter, startsWith, strip, stripLeft;

/// Parses sub-package paths from the root `dub.sdl`.
@safe
string[] parseSubPackages(string repoRoot)
{
    const dubSdlPath = repoRoot.buildPath("dub.sdl");
    if (!dubSdlPath.exists)
        return [];

    return dubSdlPath.readText
        .lineSplitter
        .map!(line => line.parseSdlStringField("subPackage"))
        .filter!(pkg => pkg.length > 0)
        .array;
}

/// Extracts the value of a top-level SDL field of the form `<name> "<value>"`.
/// Returns null when `line` doesn't open with that field. Used by
/// `parseSubPackages` and `inTreePackageNames` so both share one parser.
@safe pure
private string parseSdlStringField(in char[] line, in char[] field)
{
    auto stripped = line.stripLeft;
    if (!stripped.startsWith(field))
        return null;

    auto rest = stripped[field.length .. $];

    // Skip all whitespace after the field name
    import std.ascii : isWhite;
    size_t i = 0;
    while (i < rest.length && rest[i].isWhite)
        i++;

    rest = rest[i .. $];

    if (!rest.startsWith('"'))
        return null;

    rest = rest[1 .. $];
    auto end = rest.indexOf('"');
    return end > 0 ? rest[0 .. end].idup : null;
}

@("dub_deps.parseSdlStringField")
@safe pure
unittest
{
    assert(parseSdlStringField(`name "sparkles"`, "name") == "sparkles");
    assert(parseSdlStringField(`  name "sparkles"`, "name") == "sparkles");
    assert(parseSdlStringField(`name  "sparkles"`, "name") == "sparkles");
    assert(parseSdlStringField(`name	"sparkles"`, "name") == "sparkles");
    assert(parseSdlStringField(`dependency "sparkles:core-cli" version="*"`, "dependency") == "sparkles:core-cli");
    assert(parseSdlStringField(`other "value"`, "name") is null);
    assert(parseSdlStringField(`name "no-closing-quote`, "name") is null);

    // Empty input and field-only lines
    assert(parseSdlStringField(``, "name") is null);
    assert(parseSdlStringField(`name`, "name") is null);
    assert(parseSdlStringField(`name `, "name") is null);

    // Empty quoted value yields null (end > 0 guard)
    assert(parseSdlStringField(`name ""`, "name") is null);

    // Field is a prefix of another identifier — quote check rejects it
    assert(parseSdlStringField(`names "foo"`, "name") is null);
    assert(parseSdlStringField(`subPackages "x"`, "subPackage") is null);

    // Real-world subPackage line from this repo
    assert(parseSdlStringField(`subPackage "libs/core-cli"`, "subPackage") == "libs/core-cli");

    // Surrounding noise after the value is ignored — we only need the first quoted token
    assert(parseSdlStringField(`name "sparkles" // trailing`, "name") == "sparkles");
}

/// Names of all packages — root + subpackages — that live in this repo.
/// Used to decide which `dependency "<name>" version="*"` lines in
/// markdown examples should be redirected to the local working copy
/// during `docs run`/`verify`/`update`.
@safe
private string[] inTreePackageNames(string repoRoot)
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
    if (!dubSdlPath.exists)
        return null;
    foreach (line; dubSdlPath.readText.lineSplitter)
    {
        auto name = line.parseSdlStringField("name");
        if (name.length)
            return name;
    }
    return null;
}

/// Rewrites `dependency "<pkg>" version="*"` lines for any in-tree
/// subpackage to `dependency "<pkg>" path="<rel>"`, where `<rel>` is
/// the relative path from `fromDir` (the example's directory) up to
/// the repo root. This lets `docs run`/`verify`/`update` exercise the
/// local working copy of the new code, instead of dub silently
/// resolving against an older registry-published version that may
/// lack the API the example demonstrates.
///
/// Lines that don't match the exact `version="*"` form are left alone
/// — examples that pin to a specific version do so deliberately.
@safe
string rewriteInTreeDeps(string code, string repoRoot, string fromDir)
{
    auto names = repoRoot.inTreePackageNames;
    if (names.length == 0)
        return code;

    auto rel = repoRoot.relativePath(fromDir);

    // Detect newline type from the first line break
    const nl = code.indexOf("\r\n") >= 0 ? "\r\n" : "\n";

    auto rewritten = code
        .lineSplitter
        .map!(line => line.rewriteDepLine(names, rel))
        .join(nl);

    return code.endsWith(nl) && !rewritten.endsWith(nl)
        ? rewritten ~ nl
        : rewritten;
}

@safe pure
private string rewriteDepLine(in char[] line, in string[] names, string rel)
{
    auto leftStripped = line.stripLeft;
    auto name = leftStripped.parseSdlStringField("dependency");
    if (!names.canFind(name))
        return line.idup;

    // Only rewrite the version="*" form; other version specifiers and
    // existing path="..." references are intentional and untouched.
    auto firstQuote = leftStripped.indexOf('"');
    if (firstQuote < 0) return line.idup;

    auto closingQuote = leftStripped.indexOf('"', firstQuote + 1);
    if (closingQuote < 0) return line.idup;

    if (leftStripped[closingQuote + 1 .. $].strip != `version="*"`)
        return line.idup;

    auto indent = line[0 .. line.length - leftStripped.length];
    return text(indent, `dependency "`, name, `" path="`, rel, `"`);
}

@("dub_deps.rewriteDepLine")
@safe pure
unittest
{
    const rel = "..";
    const names = ["sparkles", "sparkles:core-cli"];

    // Basic rewrite
    assert(rewriteDepLine(`dependency "sparkles:core-cli" version="*"`, names, rel)
        == `dependency "sparkles:core-cli" path=".."`);

    // Indentation is preserved verbatim
    assert(rewriteDepLine(`    dependency "sparkles" version="*"`, names, rel)
        == `    dependency "sparkles" path=".."`);
    assert(rewriteDepLine("\tdependency \"sparkles\" version=\"*\"", names, rel)
        == "\tdependency \"sparkles\" path=\"..\"");

    // Out-of-tree packages are not rewritten
    assert(rewriteDepLine(`dependency "other" version="*"`, names, rel)
        == `dependency "other" version="*"`);

    // Pinned versions and existing path= lines are left alone
    assert(rewriteDepLine(`dependency "sparkles" version="~>1.0.0"`, names, rel)
        == `dependency "sparkles" version="~>1.0.0"`);
    assert(rewriteDepLine(`dependency "sparkles" path="."`, names, rel)
        == `dependency "sparkles" path="."`);

    // Lines without a `dependency` field are passed through unchanged
    assert(rewriteDepLine(`import sparkles;`, names, rel)
        == `import sparkles;`);
    assert(rewriteDepLine(``, names, rel) == ``);

    // Different relative paths are inserted verbatim
    assert(rewriteDepLine(`dependency "sparkles" version="*"`, names, "../../..")
        == `dependency "sparkles" path="../../.."`);
}

version (unittest)
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.uuid : randomUUID;

    /// Creates a fresh empty tempdir under `tempDir`. Caller is responsible
    /// for `rmdirRecurse`-ing the returned path (typically via `scope(exit)`).
    @safe
    private string makeTmpDir(string label)
    {
        auto path = tempDir.buildPath(label ~ "-" ~ randomUUID.toString);
        mkdirRecurse(path);
        return path;
    }
}

@("dub_deps.rewriteInTreeDeps.no-in-tree-packages")
@safe
unittest
{
    // When inTreePackageNames returns nothing (no dub.sdl), code passes through unchanged.
    const root = makeTmpDir("ci-rewrite-empty");
    scope(exit) rmdirRecurse(root);

    const code = `dependency "sparkles" version="*"`;
    assert(rewriteInTreeDeps(code, root, root) == code);
}

@("dub_deps.rewriteInTreeDeps.rewrites-only-in-tree")
@safe
unittest
{
    // Build a minimal repo layout:
    //   <root>/dub.sdl                          (name "sparkles", two subPackages)
    //   <root>/libs/core-cli/dub.sdl            (name "core-cli")
    //   <root>/libs/test-utils/dub.sdl          (name "test-utils")
    //   <root>/examples/                        (fromDir — example lives here)
    const root = makeTmpDir("ci-rewrite-tree");
    scope(exit) rmdirRecurse(root);

    mkdirRecurse(buildPath(root, "libs", "core-cli"));
    mkdirRecurse(buildPath(root, "libs", "test-utils"));
    mkdirRecurse(buildPath(root, "examples"));

    write(buildPath(root, "dub.sdl"),
        "name \"sparkles\"\n"
        ~ "subPackage \"libs/core-cli\"\n"
        ~ "subPackage \"libs/test-utils\"\n");
    write(buildPath(root, "libs", "core-cli", "dub.sdl"), "name \"core-cli\"\n");
    write(buildPath(root, "libs", "test-utils", "dub.sdl"), "name \"test-utils\"\n");

    const fromDir = buildPath(root, "examples");
    // relativePath("<root>", "<root>/examples") == ".."
    const code =
        "name \"demo\"\n"
        ~ "dependency \"sparkles\" version=\"*\"\n"
        ~ "dependency \"sparkles:core-cli\" version=\"*\"\n"
        ~ "dependency \"sparkles:test-utils\" version=\"*\"\n"
        ~ "dependency \"other\" version=\"*\"\n"
        ~ "dependency \"sparkles\" version=\"~>1.0\"\n";

    const expected =
        "name \"demo\"\n"
        ~ "dependency \"sparkles\" path=\"..\"\n"
        ~ "dependency \"sparkles:core-cli\" path=\"..\"\n"
        ~ "dependency \"sparkles:test-utils\" path=\"..\"\n"
        ~ "dependency \"other\" version=\"*\"\n"
        ~ "dependency \"sparkles\" version=\"~>1.0\"\n";

    assert(rewriteInTreeDeps(code, root, fromDir) == expected);
}

@("dub_deps.rewriteInTreeDeps.preserves-crlf")
@safe
unittest
{
    const root = makeTmpDir("ci-rewrite-crlf");
    scope(exit) rmdirRecurse(root);

    write(buildPath(root, "dub.sdl"), "name \"sparkles\"\n");

    const code = "dependency \"sparkles\" version=\"*\"\r\nimport sparkles;\r\n";
    const expected = "dependency \"sparkles\" path=\".\"\r\nimport sparkles;\r\n";
    assert(rewriteInTreeDeps(code, root, root) == expected);
}

@("dub_deps.readPackageName")
@safe
unittest
{
    const root = makeTmpDir("ci-read-pkg-name");
    scope(exit) rmdirRecurse(root);

    // Missing file returns null
    assert(readPackageName(buildPath(root, "missing.sdl")) is null);

    // First matching `name "..."` line wins, even when surrounded by other fields
    const sdlPath = buildPath(root, "dub.sdl");
    write(sdlPath,
        "// header comment\n"
        ~ "description \"a package\"\n"
        ~ "name \"sparkles\"\n"
        ~ "name \"ignored-second\"\n");
    assert(readPackageName(sdlPath) == "sparkles");

    // dub.sdl with no `name` field returns null
    const noNamePath = buildPath(root, "no-name.sdl");
    write(noNamePath, "description \"missing name\"\n");
    assert(readPackageName(noNamePath) is null);
}

@("dub_deps.inTreePackageNames")
@safe
unittest
{
    import std.conv : to;

    const root = makeTmpDir("ci-in-tree-names");
    scope(exit) rmdirRecurse(root);

    mkdirRecurse(buildPath(root, "libs", "core-cli"));
    mkdirRecurse(buildPath(root, "libs", "test-utils"));
    mkdirRecurse(buildPath(root, "libs", "broken")); // listed but has no dub.sdl

    write(buildPath(root, "dub.sdl"),
        "name \"sparkles\"\n"
        ~ "subPackage \"libs/core-cli\"\n"
        ~ "subPackage \"libs/test-utils\"\n"
        ~ "subPackage \"libs/broken\"\n");
    write(buildPath(root, "libs", "core-cli", "dub.sdl"), "name \"core-cli\"\n");
    write(buildPath(root, "libs", "test-utils", "dub.sdl"), "name \"test-utils\"\n");

    auto names = inTreePackageNames(root);
    assert(names == ["sparkles", "sparkles:core-cli", "sparkles:test-utils"],
        "unexpected names: " ~ names.to!string);

    // No root dub.sdl → empty
    const empty = makeTmpDir("ci-in-tree-empty");
    scope(exit) rmdirRecurse(empty);
    assert(inTreePackageNames(empty).length == 0);
}
