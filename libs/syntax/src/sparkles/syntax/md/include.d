/**
VitePress file inclusion for markdown documents: the `@include` comment
directive and the `<<<` code-snippet import.

Both are expanded as a text pre-pass, before the markdown is parsed, the way
VitePress expands them: an include directive on a line of its own is replaced
by the named file's text (expanded recursively), and a snippet import is
replaced by a fenced code block holding the named file.

Each form names a path — relative to the including file, or `@/`-prefixed
from the source root — optionally followed by `#region` and a `{start,end}`
line range (an include) or `{highlight lang}` (a snippet), and for a snippet a
`[label]`. Every path must stay inside the confinement root; a missing file,
an unknown region, a cycle or nesting deeper than $(LREF maxIncludeDepth)
becomes a visible caution block where the directive stood, never a silent
omission.

File access goes through a caller-supplied reader, so the expansion is
testable without a filesystem; $(LREF expandIncludesFromDisk) wires the real
one, with the roots found by $(LREF discoverIncludeRoots).
*/
module sparkles.syntax.md.include;

import std.algorithm.searching : canFind, endsWith, findSplit, startsWith;
import std.array : Appender;
import std.path : absolutePath, buildNormalizedPath, dirName, extension;
import std.string : indexOf, lineSplitter, strip, stripLeft, stripRight;
import std.typecons : Yes;

/// Deepest chain of nested includes before expansion stops with an error.
enum maxIncludeDepth = 8;

/// The directories that resolve and bound a directive's path.
struct IncludeRoots
{
    /// What `@/` names — VitePress's source directory.
    string sourceRoot;
    /// No path may resolve outside this directory (the repository).
    string confineRoot;
}

/// Reads a whole file. Returns `false` (and leaves `text` unset) when the
/// file cannot be read.
alias IncludeReader = bool delegate(string path, out string text) @safe;

/// Expands every directive in `source`, a document in directory `docDir`.
/// Text without directives comes back unchanged (the same slice).
string expandIncludes(string source, string docDir, IncludeRoots roots,
    scope IncludeReader read) @safe
{
    if (!mayHaveDirective(source))
        return source;
    Appender!string output;
    string[] stack;
    expandInto(output, source, docDir, roots, read, stack);
    return output[];
}

/// `expandIncludes` with the files read from disk and the roots discovered
/// from `docPath`.
string expandIncludesFromDisk(string source, string docPath) @trusted
{
    import std.file : readText;

    if (!mayHaveDirective(source))
        return source;
    const dir = dirName(absolutePath(docPath));
    const roots = discoverIncludeRoots(dir);
    const realRoot = realPathOf(roots.confineRoot);
    bool readFile(string path, out string text) @trusted
    {
        // The lexical check in `resolve` cannot see through a symlink; the
        // file it names must also lie inside the root once resolved.
        const resolved = realPathOf(path);
        if (resolved is null || realRoot is null
            || (resolved != realRoot && !resolved.startsWith(realRoot ~ "/")))
            return false;
        try
        {
            text = readText(path);
            return true;
        }
        catch (Exception)
            return false;
    }

    return expandIncludes(source, dir, roots, &readFile);
}

/**
The roots for a document in `docDir`: the source root is the nearest
directory at or above it holding `.vitepress` (else `docDir`); the
confinement root is the nearest holding `.git` (else the source root).
*/
IncludeRoots discoverIncludeRoots(string docDir) @trusted
{
    import std.file : exists;
    import std.path : buildPath;

    string nearest(string marker)
    {
        for (string d = docDir;;)
        {
            if (exists(buildPath(d, marker)))
                return d;
            const up = dirName(d);
            if (up == d)
                return null;
            d = up;
        }
    }

    IncludeRoots roots;
    roots.sourceRoot = nearest(".vitepress");
    if (roots.sourceRoot is null)
        roots.sourceRoot = docDir;
    roots.confineRoot = nearest(".git");
    if (roots.confineRoot is null)
        roots.confineRoot = roots.sourceRoot;
    return roots;
}

/// The canonical path of an existing file or directory, or `null`.
private string realPathOf(string path) @trusted
{
    version (Posix)
    {
        import core.stdc.stdlib : free;
        import core.sys.posix.stdlib : realpath;
        import std.string : fromStringz, toStringz;

        auto p = realpath(path.toStringz, null);
        if (p is null)
            return null;
        scope (exit)
            free(p);
        return p.fromStringz.idup;
    }
    else
    {
        import std.file : exists;

        return exists(path) ? buildNormalizedPath(absolutePath(path)) : null;
    }
}

private:

bool mayHaveDirective(string source) @safe pure nothrow @nogc
    => source.canFind("@include") || source.canFind("<<<");

void expandInto(ref Appender!string output, string source, string docDir,
    IncludeRoots roots, scope IncludeReader read, ref string[] stack) @safe
{
    bool inFence;
    string fenceMarker;
    foreach (line; source.lineSplitter!(Yes.keepTerminator))
    {
        const bare = line.stripRight;
        const body = bare.stripLeft;
        // Inside a fenced code block a snippet import is code, but an include
        // still expands: VitePress replaces include comments across the whole
        // text before it parses (`processIncludes`), which is how a licence
        // fills a `text` fence on the credits pages.
        if (inFence)
        {
            Directive d;
            if (body.startsWith(fenceMarker) && body.strip == body[0 .. fenceRun(body)])
                inFence = false;
            else if (parseInclude(body, d))
            {
                expandDirective(output, d, docDir, roots, read, stack);
                continue;
            }
            output ~= line;
            continue;
        }
        if (const run = fenceRun(body))
        {
            inFence = true;
            fenceMarker = body[0 .. run];
            output ~= line;
            continue;
        }
        Directive d;
        if (parseInclude(body, d) || parseSnippet(body, d))
            expandDirective(output, d, docDir, roots, read, stack);
        else
            output ~= line;
    }
}

/// The length of a run of three or more backticks or tildes opening `s`.
size_t fenceRun(scope const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length < 3 || (s[0] != '`' && s[0] != '~'))
        return 0;
    size_t n;
    while (n < s.length && s[n] == s[0])
        n++;
    return n >= 3 ? n : 0;
}

struct Directive
{
    bool snippet;
    string path;
    string region;
    bool hasRange;
    size_t first, last; // 1-based, inclusive; last == 0 means "to the end"
    string lang;
    string label;
}

/// `<!--@include: path#region{start,end}-->`, alone on its line.
bool parseInclude(string body, out Directive d) @safe pure
{
    if (!body.startsWith("<!--") || !body.endsWith("-->"))
        return false;
    auto inner = body[4 .. $ - 3].strip;
    if (!inner.startsWith("@include:"))
        return false;
    auto spec = inner["@include:".length .. $].strip;
    const brace = spec.indexOf('{');
    if (brace >= 0 && spec.endsWith("}"))
    {
        if (!parseRange(spec[brace + 1 .. $ - 1], d))
            return false;
        spec = spec[0 .. brace];
    }
    splitRegion(spec, d);
    return d.path.length != 0;
}

/// `<<< path#region{highlight lang} [label]`, alone on its line.
bool parseSnippet(string body, out Directive d) @safe pure
{
    if (!body.startsWith("<<< "))
        return false;
    d.snippet = true;
    auto spec = body[4 .. $].strip;
    const open = spec.endsWith("]") ? spec.indexOf('[') : -1;
    if (open >= 0)
        {
            d.label = spec[open .. $];
            spec = spec[0 .. open].stripRight;
        }
    const brace = spec.indexOf('{');
    if (brace >= 0 && spec.endsWith("}"))
    {
        // `{1,3-4 ts}`, `{ts}` or `{2}`: line highlights, then a language.
        foreach (word; spec[brace + 1 .. $ - 1].splitWords)
            if (!isHighlightSpec(word))
                d.lang = word;
        spec = spec[0 .. brace];
    }
    splitRegion(spec, d);
    if (d.lang.length == 0)
    {
        const ext = extension(d.path);
        d.lang = ext.length > 1 ? ext[1 .. $] : "";
    }
    return d.path.length != 0;
}

string[] splitWords(string s) @safe pure
{
    import std.array : split;

    return s.split;
}

bool isHighlightSpec(string word) @safe pure nothrow @nogc
{
    foreach (c; word)
        if (!(c >= '0' && c <= '9') && c != ',' && c != '-')
            return false;
    return word.length != 0;
}

void splitRegion(string spec, ref Directive d) @safe pure
{
    if (auto parts = spec.findSplit("#"))
    {
        d.path = parts[0].strip;
        d.region = parts[2].strip;
    }
    else
        d.path = spec.strip;
}

/// `3,5`, `3,`, `,5` or `3` (a single line).
bool parseRange(string s, ref Directive d) @safe pure
{
    import std.conv : to, ConvException;

    d.hasRange = true;
    try
    {
        if (auto parts = s.findSplit(","))
        {
            d.first = parts[0].strip.length ? parts[0].strip.to!size_t : 1;
            d.last = parts[2].strip.length ? parts[2].strip.to!size_t : 0;
        }
        else
            d.first = d.last = s.strip.to!size_t;
    }
    catch (ConvException)
        return false;
    return d.first != 0;
}

void expandDirective(ref Appender!string output, Directive d, string docDir,
    IncludeRoots roots, scope IncludeReader read, ref string[] stack) @safe
{
    string path;
    if (auto err = resolve(d.path, docDir, roots, path))
        return caution(output, d, err);
    if (stack.canFind(path))
        return caution(output, d, "include cycle: " ~ d.path ~ " includes itself");
    if (stack.length >= maxIncludeDepth)
        return caution(output, d, "includes nested deeper than 8");
    string text;
    if (!read(path, text))
        return caution(output, d, "cannot read " ~ d.path);
    if (d.region.length)
    {
        bool found;
        text = regionOf(text, d.region, found);
        if (!found)
            return caution(output, d, "no region '" ~ d.region ~ "' in " ~ d.path);
    }
    if (d.hasRange)
        text = linesOf(text, d.first, d.last);

    if (d.snippet)
    {
        // A fence one backtick longer than any run in the body cannot be
        // closed by it.
        const fence = backtickFence(text);
        output ~= fence;
        output ~= d.lang;
        if (d.label.length)
        {
            output ~= ' ';
            output ~= d.label;
        }
        output ~= '\n';
        output ~= text;
        if (text.length && text[$ - 1] != '\n')
            output ~= '\n';
        output ~= fence;
        output ~= '\n';
        return;
    }
    stack ~= path;
    scope (exit)
        stack = stack[0 .. $ - 1];
    expandInto(output, text, dirName(path), roots, read, stack);
    if (text.length && text[$ - 1] != '\n')
        output ~= '\n';
}

/// Resolves `spec` to a normalized absolute path inside the confinement
/// root, or returns why it cannot.
string resolve(string spec, string docDir, IncludeRoots roots, out string path) @safe
{
    import std.path : buildPath, isAbsolute;

    if (spec.startsWith("@/"))
        path = buildNormalizedPath(roots.sourceRoot, spec[2 .. $]);
    else if (isAbsolute(spec))
        return "absolute paths are not allowed: " ~ spec;
    else
        path = buildNormalizedPath(docDir, spec);
    const root = buildNormalizedPath(roots.confineRoot);
    if (path != root && !path.startsWith(root ~ "/"))
        return "outside the repository: " ~ spec;
    return null;
}

void caution(ref Appender!string output, Directive d, string why) @safe
{
    output ~= "\n> [!CAUTION]\n> ";
    output ~= d.snippet ? "Snippet import failed: " : "Include failed: ";
    output ~= why;
    output ~= "\n\n";
}

/// The lines between `#region name` and `#endregion name` markers (any
/// comment syntax), markers excluded.
string regionOf(string text, string name, out bool found) @safe pure
{
    Appender!string output;
    bool inside;
    foreach (line; text.lineSplitter!(Yes.keepTerminator))
    {
        if (!inside)
        {
            if (markerName(line, "#region") == name)
                inside = found = true;
            continue;
        }
        const end = markerName(line, "#endregion");
        if (end !is null && (end.length == 0 || end == name))
            return output[];
        // Nested markers of other regions are not content.
        if (markerName(line, "#region") is null)
            output ~= line;
    }
    return output[];
}

/// The name after `marker` on `line`, "" for a bare marker, or `null` when
/// the line has none.
string markerName(string line, string marker) @safe pure
{
    const at = line.indexOf(marker);
    if (at < 0)
        return null;
    auto rest = line[at + marker.length .. $];
    if (rest.length && rest[0] != ' ' && rest[0] != '\t' && rest[0] != '\n' && rest[0] != '\r')
        return null; // `#regionfoo`, or `#region` inside `#endregion`
    rest = rest.strip;
    // Trailing comment closers: `-->`, `*/`.
    foreach (closer; ["-->", "*/"])
        if (rest.endsWith(closer))
            rest = rest[0 .. $ - closer.length].stripRight;
    const space = rest.indexOf(' ');
    if (space >= 0)
        rest = rest[0 .. space];
    return rest.length ? rest : "";
}

string linesOf(string text, size_t first, size_t last) @safe pure
{
    Appender!string output;
    size_t n;
    foreach (line; text.lineSplitter!(Yes.keepTerminator))
    {
        ++n;
        if (n >= first && (last == 0 || n <= last))
            output ~= line;
    }
    return output[];
}

string backtickFence(string text) @safe pure nothrow
{
    size_t longest, run;
    foreach (c; text)
    {
        run = c == '`' ? run + 1 : 0;
        if (run > longest)
            longest = run;
    }
    const n = longest >= 3 ? longest + 1 : 3;
    auto fence = new char[n];
    fence[] = '`';
    return fence.idup;
}

version (unittest)
{
    struct FakeFs
    {
        string[string] files;
        string[] reads;

        bool read(string path, out string text) @safe
        {
            reads ~= path;
            if (auto p = path in files)
            {
                text = *p;
                return true;
            }
            return false;
        }
    }

    immutable roots = IncludeRoots(sourceRoot: "/repo/docs", confineRoot: "/repo");
}

@("md.include.noDirectiveReturnsTheSameText")
@safe unittest
{
    FakeFs fs;
    const src = "# Title\n\nNo directives here.\n";
    assert(expandIncludes(src, "/repo/docs", roots, &fs.read) is src);
    assert(fs.reads.length == 0);
}

@("md.include.relativeAndRecursive")
@safe unittest
{
    FakeFs fs;
    fs.files["/repo/docs/credits/parts/zlib.md"] = "## zlib\n\n<!--@include: ../licenses/zlib/LICENSE-->\n";
    fs.files["/repo/docs/credits/licenses/zlib/LICENSE"] = "Copyright (C) Jean-loup Gailly\n";
    const src = "# Credits\n<!--@include: ./parts/zlib.md-->\nEnd\n";
    assert(expandIncludes(src, "/repo/docs/credits", roots, &fs.read)
        == "# Credits\n## zlib\n\nCopyright (C) Jean-loup Gailly\nEnd\n");
}

@("md.include.sourceRootRangeAndRegion")
@safe unittest
{
    FakeFs fs;
    fs.files["/repo/docs/parts/basics.md"] = "one\ntwo\nthree\nfour\n";
    fs.files["/repo/docs/parts/regions.md"] =
        "head\n<!-- #region usage -->\nuse it\n<!-- #endregion usage -->\ntail\n";
    assert(expandIncludes("<!--@include: @/parts/basics.md{2,3}-->\n", "/repo/docs/a",
        roots, &fs.read) == "two\nthree\n");
    assert(expandIncludes("<!--@include: @/parts/basics.md{3,}-->\n", "/repo/docs",
        roots, &fs.read) == "three\nfour\n");
    assert(expandIncludes("<!--@include: @/parts/basics.md{,1}-->\n", "/repo/docs",
        roots, &fs.read) == "one\n");
    assert(expandIncludes("<!--@include: ./parts/regions.md#usage-->\n", "/repo/docs",
        roots, &fs.read) == "use it\n");
}

@("md.include.snippetBecomesALabelledFence")
@safe unittest
{
    FakeFs fs;
    fs.files["/repo/docs/libs/eh/snippets/timers.d"] = "void main()\n{\n}\n";
    fs.files["/repo/apps/ui-gallery/test/full.ansi"] = "\x1b[1mbold\x1b[0m\n";
    assert(expandIncludes("<<< @/libs/eh/snippets/timers.d [event-horizon]\n", "/repo/docs/libs/eh",
        roots, &fs.read) == "```d [event-horizon]\nvoid main()\n{\n}\n```\n");
    // `@/../` reaches the rest of the repository; `{ansi}` names the language.
    assert(expandIncludes("<<< @/../apps/ui-gallery/test/full.ansi{ansi} [full]\n", "/repo/docs",
        roots, &fs.read) == "```ansi [full]\n\x1b[1mbold\x1b[0m\n```\n");
}

@("md.include.snippetHighlightsAndRegion")
@safe unittest
{
    FakeFs fs;
    fs.files["/repo/docs/s.ts"] = "a\n// #region main\nb\nc\n// #endregion main\nd\n";
    assert(expandIncludes("<<< ./s.ts#main{1,2 typescript}\n", "/repo/docs", roots, &fs.read)
        == "```typescript\nb\nc\n```\n");
}

@("md.include.snippetFenceOutgrowsBackticksInTheBody")
@safe unittest
{
    FakeFs fs;
    fs.files["/repo/docs/doc.md"] = "````\nnested\n````\n";
    assert(expandIncludes("<<< ./doc.md\n", "/repo/docs", roots, &fs.read)
        == "`````md\n````\nnested\n````\n`````\n");
}

@("md.include.insideAFenceOnlyIncludesExpand")
@safe unittest
{
    FakeFs fs;
    fs.files["/repo/docs/LICENSE"] = "MIT\n";
    // As on the site: the include fills the fence, the snippet stays code.
    const src = "```text\n<!-- @include: ./LICENSE -->\n<<< ./y.d\n```\n";
    assert(expandIncludes(src, "/repo/docs", roots, &fs.read)
        == "```text\nMIT\n<<< ./y.d\n```\n");
    assert(fs.reads == ["/repo/docs/LICENSE"]);
}

@("md.include.confinedToTheRepository")
@safe unittest
{
    FakeFs fs;
    fs.files["/etc/passwd"] = "root:x:0:0\n";
    foreach (src; ["<!--@include: ../../../etc/passwd-->\n", "<<< @/../../etc/passwd\n",
            "<!--@include: /etc/passwd-->\n"])
    {
        const got = expandIncludes(src, "/repo/docs", roots, &fs.read);
        assert(got.canFind("[!CAUTION]"), got);
        assert(!got.canFind("root:x"), got);
    }
    assert(fs.reads.length == 0);
}

@("md.include.failuresAreVisible")
@safe unittest
{
    FakeFs fs;
    fs.files["/repo/docs/a.md"] = "<!--@include: ./b.md-->\n";
    fs.files["/repo/docs/b.md"] = "<!--@include: ./a.md-->\n";
    fs.files["/repo/docs/r.md"] = "text\n";
    const cycle = expandIncludes("<!--@include: ./a.md-->\n", "/repo/docs", roots, &fs.read);
    assert(cycle.canFind("Include failed: include cycle"), cycle);
    assert(expandIncludes("<!--@include: ./missing.md-->\n", "/repo/docs", roots, &fs.read)
        .canFind("Include failed: cannot read ./missing.md"));
    assert(expandIncludes("<!--@include: ./r.md#nope-->\n", "/repo/docs", roots, &fs.read)
        .canFind("no region 'nope'"));
}

@("md.include.depthIsBounded")
@safe unittest
{
    import std.conv : text;

    FakeFs fs;
    foreach (i; 0 .. 20)
        fs.files[text("/repo/docs/n", i, ".md")] = text("<!--@include: ./n", i + 1, ".md-->\n");
    const got = expandIncludes("<!--@include: ./n0.md-->\n", "/repo/docs", roots, &fs.read);
    assert(got.canFind("nested deeper than 8"), got);
    assert(fs.reads.length == maxIncludeDepth);
}

@("md.include.notADirective")
@safe unittest
{
    FakeFs fs;
    // Inline mentions, a comment that is not an include, and `<<<` without a
    // path are ordinary text.
    const src = "Use `<!--@include: x-->` inline.\n<!-- a comment -->\n<<<\nx <<< y\n";
    assert(expandIncludes(src, "/repo/docs", roots, &fs.read) == src);
}

@("md.include.fromDiskFollowsNoSymlinkOutOfTheRepository")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : text;

    version (Posix)
    {
        import std.file : symlink;

        const base = buildPath(tempDir, text("sparkles-md-include-", thisProcessID));
        scope (exit)
            rmdirRecurse(base);
        const repo = buildPath(base, "repo");
        mkdirRecurse(buildPath(repo, ".git"));
        mkdirRecurse(buildPath(repo, "docs", ".vitepress"));
        write(buildPath(base, "secret.txt"), "outside\n");
        write(buildPath(repo, "docs", "part.md"), "inside\n");
        symlink(buildPath(base, "secret.txt"), buildPath(repo, "docs", "link.md"));

        const doc = buildPath(repo, "docs", "page.md");
        assert(expandIncludesFromDisk("<!--@include: ./part.md-->\n", doc) == "inside\n");
        const got = expandIncludesFromDisk("<!--@include: ./link.md-->\n", doc);
        assert(!got.canFind("outside"), got);
        assert(got.canFind("Include failed"), got);
        // `@/` is the directory holding `.vitepress`.
        assert(expandIncludesFromDisk("<!--@include: @/part.md-->\n",
            buildPath(repo, "docs", "sub", "x.md")) == "inside\n");
    }
}
