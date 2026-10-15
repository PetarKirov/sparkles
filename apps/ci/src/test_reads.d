/++
Check that every repository file a package's sources name is in what CI keys
that package's tests by (`--check-test-reads`).

CI re-runs a package's tests only when its unit closure is new
(`nix/ci/lib/graph.nix`): its own directory, the sub-packages its recipe
reaches, the dub manifests, and the paths `nix/ci/test-reads.json` lists under
`reads`. A test that opens a file outside that closure passes stale: the file
changes, the stamp does not, and nothing re-runs. This check makes such a read
fail at commit time instead of passing silently forever.

It reads each package's compiled sources (`src/`, `source/`, `test/`,
`tests/`) and collects the repository paths they name ($(LREF namedPaths)):

$(LIST
    $(ITEM a string literal holding a `/`, read from the repository root — where
        `dub test` runs — or, when it opens with `../`, from the file's own
        directory;)
    $(ITEM the segments of a `buildPath` call, joined, from the file's
        directory when the call starts from `__FILE_FULL_PATH__` and from the
        root otherwise.)
)

A named path counts only if it exists, so a fixture's made-up `docs/a.md` is
not a read. One that exists and lies outside the closure is reported, and is
settled in `nix/ci/test-reads.json`: under `reads` when a test really opens
it (CI then keys the package by it), under `ignore` when the package only
names it — a runtime path of the tool, a string a test parses.

Split out from `app.d` so the scanner and the matcher are unit-tested (the
main source file is excluded from the auto-generated test runner).
+/
module test_reads;

import std.algorithm : any, canFind, filter, map, sort, startsWith, uniq;
import std.array : array, join, split;
import std.json : parseJSON;
import std.path : buildNormalizedPath, dirName;
import std.regex : ctRegex, matchAll;

/// Where the reads and the ignores are kept, relative to the repository root.
enum testReadsFile = "nix/ci/test-reads.json";

/// The directories of a package that `dub test` compiles, by convention.
immutable string[] sourceDirs = ["src", "source", "test", "tests"];

/// A token of D source, as far as this check needs one.
struct Token
{
    enum Kind { str, ident, punct }
    Kind kind;
    string text; /// a string's value, an identifier, or one punctuation character
}

/++
Splits D source into string literals, identifiers and punctuation, skipping
comments (a DDoc link is not a read) and character literals. Escapes in a
string are kept as written: a path holds none worth decoding.
+/
@safe pure
Token[] tokenize(string src)
{
    import std.ascii : isAlphaNum;

    Token[] tokens;
    size_t i = 0;
    const n = src.length;

    while (i < n)
    {
        const c = src[i];
        if (c == '/' && i + 1 < n && src[i + 1] == '/')
        {
            while (i < n && src[i] != '\n')
                i++;
        }
        else if (c == '/' && i + 1 < n && src[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/'))
                i++;
            i += 2;
        }
        else if (c == '/' && i + 1 < n && src[i + 1] == '+')
        {
            size_t depth = 1;
            i += 2;
            while (i + 1 < n && depth)
            {
                if (src[i] == '/' && src[i + 1] == '+')
                {
                    depth++;
                    i += 2;
                }
                else if (src[i] == '+' && src[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                }
                else
                    i++;
            }
        }
        else if (c == '"' || c == '`' || (c == 'r' && i + 1 < n && src[i + 1] == '"'))
        {
            const raw = c != '"';
            const close = c == '`' ? '`' : '"';
            i += c == 'r' ? 2 : 1;
            const start = i;
            while (i < n && src[i] != close)
                i += (!raw && src[i] == '\\') ? 2 : 1;
            tokens ~= Token(Token.Kind.str, src[start .. i < n ? i : n]);
            i++;
        }
        else if (c == '\'')
        {
            i++;
            while (i < n && src[i] != '\'')
                i += src[i] == '\\' ? 2 : 1;
            i++;
        }
        else if (isAlphaNum(c) || c == '_')
        {
            const start = i;
            while (i < n && (isAlphaNum(src[i]) || src[i] == '_'))
                i++;
            tokens ~= Token(Token.Kind.ident, src[start .. i]);
        }
        else
        {
            if (c > ' ')
                tokens ~= Token(Token.Kind.punct, src[i .. i + 1]);
            i++;
        }
    }
    return tokens;
}

@("test_reads.tokenize.skipsCommentsAndCharLiterals")
@safe pure
unittest
{
    const t = tokenize(`/// see "docs/a.md"
/+ nested /+ "x/y" +/ +/ auto p = "docs/b.md"; char q = '"'; enum r = r"c\d"; // "e/f"`);
    assert(t.filter!(x => x.kind == Token.Kind.str).map!(x => x.text).array == ["docs/b.md", `c\d`]);
}

/// Resolves `rel` against the repository-relative directory `base` (`""` for
/// the root), or returns `null` when it climbs out of the repository.
@safe pure
string resolve(string base, string rel)
{
    string[] parts = base.length ? base.split("/") : [];
    foreach (seg; rel.split("/"))
    {
        if (seg == "" || seg == ".")
            continue;
        if (seg == "..")
        {
            if (!parts.length)
                return null;
            parts = parts[0 .. $ - 1];
        }
        else
            parts ~= seg;
    }
    return parts.join("/");
}

@("test_reads.resolve")
@safe pure
unittest
{
    assert(resolve("libs/ui/src", "../../../docs/x.md") == "docs/x.md");
    assert(resolve("", "docs/./x.md") == "docs/x.md");
    assert(resolve("libs", "../../x") is null);
}

/++
The repository paths one source file names (see the module comment). `fileRel`
is the file's repository-relative path; nothing is checked for existence here.
+/
@safe pure
string[] namedPaths(string source, string fileRel)
{
    const fileDir = fileRel.dirName == "." ? "" : fileRel.dirName;
    const toks = tokenize(source);
    string[] found;

    foreach (t; toks)
        if (t.kind == Token.Kind.str && t.text.canFind('/') && !t.text.canFind("://"))
            if (auto p = resolve(t.text.startsWith("../") ? fileDir : "", t.text))
                found ~= p;

    foreach (k, t; toks)
    {
        if (t.kind != Token.Kind.ident || t.text != "buildPath" || k + 1 >= toks.length
            || toks[k + 1].text != "(")
            continue;

        // The receiver of a UFCS call (`__FILE_FULL_PATH__.dirName.buildPath(…)`).
        string[] receiver;
        for (size_t j = k; j >= 2 && toks[j - 1].text == "." && toks[j - 2].kind == Token.Kind.ident; j -= 2)
            receiver ~= toks[j - 2].text;

        // The arguments, split at top-level commas.
        string[][] args = [[]];
        string[] argKinds = [""];
        size_t depth = 0;
        foreach (u; toks[k + 2 .. $])
        {
            if (u.text == "(" && u.kind == Token.Kind.punct)
                depth++;
            else if (u.text == ")" && u.kind == Token.Kind.punct)
            {
                if (depth == 0)
                    break;
                depth--;
            }
            else if (u.text == "," && u.kind == Token.Kind.punct && depth == 0)
            {
                args ~= [[]];
                argKinds ~= "";
                continue;
            }
            args[$ - 1] ~= u.text;
            argKinds[$ - 1] ~= u.kind == Token.Kind.str ? "s" : "x";
        }

        // Where the path starts: a file-relative base counts its `dirName`s.
        string start = "";
        string[] segments;
        bool known = true;
        void base(in string[] expr)
        {
            if (expr.canFind("__FILE_FULL_PATH__"))
            {
                auto dir = fileRel;
                foreach (_; 0 .. expr.filter!(e => e == "dirName").array.length)
                    dir = dir.dirName == "." ? "" : dir.dirName;
                start = dir == fileRel ? fileDir : dir;
            }
        }
        if (receiver.length)
            base(receiver);
        foreach (a, kinds; argKinds)
        {
            if (kinds == "s")
                segments ~= args[a][0];
            else if (a == 0 && !receiver.length)
                base(args[a]);
            else
            {
                known = false; // a computed segment: the joined path means nothing
                break;
            }
        }
        if (known && segments.length)
            if (auto p = resolve(start, segments.join("/")))
                found ~= p;
    }
    return found.sort.uniq.array;
}

@("test_reads.namedPaths.literalsAndBuildPath")
@safe pure
unittest
{
    const src = q{
        const page = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "..", "..",
            "docs", "specs", "design-system", "capabilities.md");
        const spec = readText(buildPath(repoRoot, "docs/specs/dmd-fmt/index.md"));
        const sdl = repoRoot.buildPath("dub.sdl");
        const skip = buildPath(dir, name, "x"); // computed: no path
        const url = "https://example.com/a/b";
    };
    assert(namedPaths(src, "libs/ui/src/sparkles/ui/tokens.d") == [
        "docs/specs/design-system/capabilities.md",
        "docs/specs/dmd-fmt/index.md",
        "dub.sdl",
    ]);
}

/// One package as the check sees it.
struct Package
{
    string name; /// the directory's base name, as `dub test :<name>` takes it
    string dir;  /// repository-relative
    string[] deps; /// the `sparkles:*` names its recipe reaches
}

/++
The `sparkles:*` names a recipe reaches, read as `graph.nix`'s `refsIn` reads
them: `dependency` edges and the sibling source includes `base` and `core-cli`
use in their place. The two must agree, or this check and CI's keys diverge.
+/
@safe
string[] recipeRefs(string recipe, in string[] packageNames)
{
    string[] refs;
    foreach (m; recipe.matchAll(ctRegex!`"sparkles:([a-z0-9-]+)"`))
        refs ~= m[1];
    foreach (m; recipe.matchAll(ctRegex!`\.\./([a-z0-9-]+)/src`))
        refs ~= m[1];
    foreach (m; recipe.matchAll(ctRegex!`\.\./\.\./libs/([a-z0-9-]+)/src`))
        refs ~= m[1];
    return refs.filter!(r => packageNames.canFind(r)).array.sort.uniq.array;
}

@("test_reads.recipeRefs")
@safe
unittest
{
    const recipe = `dependency "sparkles:base" path="../.."
importPaths "src" "../test-runner/src"
dependency "sparkles:nope" path="../.."`;
    assert(recipeRefs(recipe, ["base", "test-runner"]) == ["base", "test-runner"]);
}

/// `nix/ci/test-reads.json`, parsed: package name → path prefixes.
struct TestReads
{
    string[][string] reads;  /// what a package's tests open; CI keys the package by them
    string[][string] ignore; /// what a package names but its tests do not open
}

/// Parses `nix/ci/test-reads.json` (keys starting with `$` are comments).
@safe
TestReads parseTestReads(string json)
{
    TestReads r;
    const root = parseJSON(json);
    foreach (section; ["reads", "ignore"])
    {
        if (section !in root.objectNoRef)
            continue;
        foreach (pkg, paths; root[section].objectNoRef)
        {
            if (pkg.startsWith("$"))
                continue;
            auto list = paths.arrayNoRef.map!(p => p.str).array;
            if (section == "reads")
                r.reads[pkg] = list;
            else
                r.ignore[pkg] = list;
        }
    }
    return r;
}

/// A path a package names that its CI closure does not hold.
struct UnkeyedRead
{
    string pkg;  /// the package whose sources name it
    string file; /// the source file naming it
    string path; /// the repository-relative path
}

/// Whether `path` is `prefix` or lies under it.
@safe pure nothrow @nogc
bool under(string path, string prefix) => path == prefix
    || (path.length > prefix.length && path.startsWith(prefix) && path[prefix.length] == '/');

/++
The named paths no closure covers. `named` maps a package to the
(file, path) pairs its sources name; `exists` says whether a path is in the
tree. A path is covered by the package's closure — its own directory, a
reached package's, a reached package's `reads`, a dub manifest — or by its
own `ignore`.
+/
@safe
UnkeyedRead[] unkeyedReads(
    in Package[] packages,
    in string[2][][string] named,
    in TestReads lists,
    scope bool delegate(string) @safe exists,
)
{
    import std.path : baseName;

    const(Package)* byName(string n)
    {
        foreach (ref p; packages)
            if (p.name == n)
                return &p;
        return null;
    }

    // The package that owns a path: the deepest directory holding it.
    string ownerOf(string path)
    {
        string best;
        size_t bestLen;
        foreach (ref p; packages)
            if (path.under(p.dir) && p.dir.length > bestLen)
            {
                best = p.name;
                bestLen = p.dir.length;
            }
        return best;
    }

    string[] closureOf(string name)
    {
        string[] seen;
        void visit(string n)
        {
            if (seen.canFind(n))
                return;
            seen ~= n;
            if (auto p = byName(n))
                foreach (d; p.deps)
                    visit(d);
        }
        visit(name);
        return seen;
    }

    UnkeyedRead[] result;
    foreach (ref p; packages)
    {
        const closure = closureOf(p.name);
        const keyed = closure.map!(n => lists.reads.get(n, [])).join;
        const ignored = lists.ignore.get(p.name, []);
        foreach (pair; named.get(p.name, []))
        {
            const path = pair[1];
            const manifest = path.baseName == "dub.sdl" || path.baseName == "dub.selections.json";
            if (manifest || closure.canFind(ownerOf(path)) || keyed.any!(k => path.under(k))
                || ignored.any!(k => path.under(k)) || !exists(path))
                continue;
            result ~= UnkeyedRead(p.name, pair[0], path);
        }
    }
    return result;
}

@("test_reads.unkeyedReads")
@safe
unittest
{
    const packages = [
        Package("ui", "libs/ui", ["base"]),
        Package("base", "libs/base", []),
        Package("conf", "libs/base/tools/conf", []),
    ];
    const string[2][][string] named = [
        "ui": [
            ["libs/ui/src/a.d", "libs/base/src/x.d"],        // a reached package: keyed
            ["libs/ui/src/a.d", "docs/specs/ds/caps.md"],    // unkeyed
            ["libs/ui/src/a.d", "docs/made-up.md"],          // does not exist
            ["libs/ui/src/a.d", "libs/base/tools/conf/c.d"], // a nested package ui does not reach
            ["libs/ui/src/a.d", "docs/specs/base/t.md"],     // base's reads: keyed
            ["libs/ui/src/a.d", "apps/tool/runtime.json"],   // ignored
            ["libs/ui/src/a.d", "dub.sdl"],                  // a manifest
        ],
    ];
    TestReads lists;
    lists.reads["base"] = ["docs/specs/base"];
    lists.ignore["ui"] = ["apps/tool/runtime.json"];
    const r = unkeyedReads(packages, named, lists, (string p) => p != "docs/made-up.md");
    assert(r.map!(u => u.path).array == ["docs/specs/ds/caps.md", "libs/base/tools/conf/c.d"]);
}
