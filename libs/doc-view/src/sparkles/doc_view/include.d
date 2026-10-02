/**
VitePress file inclusion for the markdown preview (hue `VIW5`, `VIW7`).

An HTML comment on a line of its own whose text is `@include:` and a path is
replaced by the referenced file's lines before the structural parse,
recursively:

$(LIST
    * `./parts/x.md` — relative to the including file;
    * `@/credits/x.md` — from the source root;
    * `x.md{3,8}`, `x.md{3,}`, `x.md{,8}` — a 1-based, inclusive line range;
    * `x.md#name` — the lines between `#region name` and `#endregion name`
        markers (any comment syntax), range applied after the region.
)

Inclusion is $(B confined and total) (`VIW7`): a path may resolve only inside
the source root or, when one is given, the wider boundary (the repository);
a missing file, an unknown region, a cycle or a depth over the limit leaves a
visible, located error line in place of the directive. Nothing is read
outside the confinement, and the included text is document text — never
executed.

The expansion is line-based and ignores markdown structure, exactly like
VitePress's own preprocessing: a directive inside a code fence is expanded
too, which is how a credits part fences its licence text.
*/
module sparkles.doc_view.include;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : appender;
import std.conv : text, to;
import std.path : buildNormalizedPath, dirName, isAbsolute;
import std.string : indexOf, KeepTerminator, lineSplitter, strip;

/// What an expansion may read, and from where.
struct IncludeOptions
{
    /// The source root `@/` resolves against and every path must stay in.
    /// Empty: $(LREF includeRoot) of the document.
    string root;
    /// A wider directory a path may also resolve into (`@/../apps/…` in the
    /// docs tree reaches the repository); empty: the root only.
    string boundary;
    /// With no `boundary`, use the repository holding the document (the
    /// nearest ancestor with a `.git`) — `VIW7`'s "only within the
    /// repository".
    bool withinRepository;
    /// Reads a file's text; null: the filesystem. A host that serves files
    /// from elsewhere (Android assets) supplies its own.
    string delegate(string path) @system read;
    /// The deepest nesting followed before an error is shown.
    int maxDepth = 8;
}

/**
The default source root for `docPath`: the nearest ancestor directory holding
`.vitepress` (the docs tree), else the document's own directory.
*/
string includeRoot(string docPath) @safe
{
    import std.file : exists, isDir;
    import std.path : absolutePath, buildPath;

    string dir;
    try
        dir = docPath.dirName.absolutePath.buildNormalizedPath;
    catch (Exception)
        return docPath.dirName;
    for (auto d = dir; ; d = d.dirName)
    {
        bool has;
        try
            has = buildPath(d, ".vitepress").exists && buildPath(d, ".vitepress").isDir;
        catch (Exception)
            has = false;
        if (has)
            return d;
        if (d.dirName == d)
            break;
    }
    return dir;
}

/// The repository `path` lies in — the nearest ancestor holding `.git` — or
/// empty when it is in none.
string repositoryOf(string path) @safe
{
    import std.file : exists;
    import std.path : absolutePath, buildPath;

    string dir;
    try
        dir = path.dirName.absolutePath.buildNormalizedPath;
    catch (Exception)
        return null;
    for (auto d = dir; ; d = d.dirName)
    {
        bool has;
        try
            has = buildPath(d, ".git").exists;
        catch (Exception)
            has = false;
        if (has)
            return d;
        if (d.dirName == d)
            return null;
    }
}

/// Whether `source` has any include directive (the expansion is skipped
/// otherwise, so a page without one keeps its exact bytes).
bool hasIncludes(scope const(char)[] source) @safe pure nothrow @nogc
{
    foreach (line; source.lineSplitter)
    {
        if (directiveOf(line).length)
            return true;
    }
    return false;
}

/**
`source` (the text of `docPath`) with every include directive replaced, per
the module header. Never throws: every failure is an error line in the text.
*/
string expandIncludes(string source, string docPath, IncludeOptions o) @system
{
    if (!hasIncludes(source))
        return source;
    if (!o.root.length)
        o.root = includeRoot(docPath);
    o.root = o.root.buildNormalizedPath;
    if (!o.boundary.length && o.withinRepository)
        o.boundary = repositoryOf(docPath);
    if (o.boundary.length)
        o.boundary = o.boundary.buildNormalizedPath;
    auto out_ = appender!string;
    string[] stack = [normalizedOf(docPath)];
    expandInto(out_, source, docPath, o, stack);
    return out_[];
}

private void expandInto(Out)(ref Out out_, string source, string docPath,
    in IncludeOptions o, ref string[] stack) @system
{
    size_t lineNo;
    foreach (line; source.lineSplitter!(KeepTerminator.yes))
    {
        lineNo++;
        const spec = directiveOf(line).idup;
        if (!spec.length)
        {
            out_ ~= line;
            continue;
        }
        const nl = line.endsWith("\n") ? "\n" : "";
        string body_;
        const err = resolveOne(spec, docPath, o, stack, body_);
        if (err.length)
        {
            out_ ~= text("> **include error** (", docPath, ":", lineNo, "): ", err, nl.length ? nl : "\n");
            continue;
        }
        out_ ~= body_;
        if (body_.length && !body_.endsWith("\n"))
            out_ ~= "\n";
    }
}



// One directive: read, select, and expand recursively. Returns an error
// message, or null with the expanded text in `result`.
private string resolveOne(string spec, string docPath, in IncludeOptions o,
    ref string[] stack, out string result) @system
{
    string path = spec, region;
    long first = 1, last = long.max;
    // `{start,end}` comes last, then `#region`.
    if (path.endsWith("}"))
    {
        const open = path.indexOf('{');
        if (open < 0)
            return "malformed line range in `" ~ spec ~ "`";
        const range = path[open + 1 .. $ - 1];
        path = path[0 .. open];
        const comma = range.indexOf(',');
        try
        {
            if (comma < 0)
                first = last = range.strip.to!long;
            else
            {
                if (range[0 .. comma].strip.length)
                    first = range[0 .. comma].strip.to!long;
                if (range[comma + 1 .. $].strip.length)
                    last = range[comma + 1 .. $].strip.to!long;
            }
        }
        catch (Exception)
            return "malformed line range in `" ~ spec ~ "`";
    }
    const hash = path.indexOf('#');
    if (hash >= 0)
    {
        region = path[hash + 1 .. $];
        path = path[0 .. hash];
    }
    if (!path.length)
        return "empty include path";

    string target;
    if (path.startsWith("@/"))
        target = buildNormalizedPath(o.root, path[2 .. $]);
    else if (path.isAbsolute)
        return "absolute include path `" ~ path ~ "` (use `@/` or a relative path)";
    else
        target = buildNormalizedPath(docPath.dirName, path);

    const norm = normalizedOf(target);
    if (!within(norm, normalizedOf(o.root)) && !(o.boundary.length && within(norm, normalizedOf(o.boundary))))
        return "`" ~ path ~ "` is outside the source root";
    foreach (s; stack)
        if (s == norm)
            return "`" ~ path ~ "` includes itself";
    if (stack.length > o.maxDepth)
        return text("includes nested deeper than ", o.maxDepth);

    string content;
    try
        content = o.read !is null ? o.read(target) : readFileText(target);
    catch (Exception e)
        return "cannot read `" ~ path ~ "`: " ~ e.msg;
    if (content is null)
        return "cannot read `" ~ path ~ "`";

    if (region.length)
    {
        string selected;
        if (!selectRegion(content, region, selected))
            return "no region `" ~ region ~ "` in `" ~ path ~ "`";
        content = selected;
    }
    if (first != 1 || last != long.max)
        content = selectLines(content, first, last);

    stack ~= norm;
    scope (exit) stack = stack[0 .. $ - 1];
    auto sub = appender!string;
    expandInto(sub, content, target, o, stack);
    result = sub[];
    return null;
}

private string readFileText(string path) @system
{
    import std.file : readText;

    return readText(path);
}

// `path` as an absolute, normalized path — or, for a path with a scheme-like
// prefix (`asset:credits/x.md`), itself normalized.
private string normalizedOf(string path) @safe
{
    import std.path : absolutePath;

    if (path.canFind(':') && !path.isAbsolute)
        return path.buildNormalizedPath;
    try
        return path.absolutePath.buildNormalizedPath;
    catch (Exception)
        return path.buildNormalizedPath;
}

private bool within(string path, string dir) @safe pure nothrow @nogc
    => path == dir || (path.length > dir.length && path.startsWith(dir)
        && (dir.endsWith("/") || path[dir.length] == '/'));

/// The path of an include directive on `line`, or empty when it is none.
private inout(char)[] directiveOf(return scope inout(char)[] line) @safe pure nothrow @nogc
{
    auto s = line.strip;
    if (!s.startsWith("<!--") || !s.endsWith("-->"))
        return null;
    auto inner = s[4 .. $ - 3].strip;
    if (!inner.startsWith("@include:"))
        return null;
    return inner["@include:".length .. $].strip;
}

// The lines strictly between `#region name` and `#endregion name`.
private bool selectRegion(string content, string name, out string selected) @safe
{
    auto sb = appender!string;
    bool inRegion, found;
    foreach (line; content.lineSplitter!(KeepTerminator.yes))
    {
        if (!inRegion && markerNames(line, "#region", name))
        {
            inRegion = found = true;
            continue;
        }
        if (inRegion && markerNames(line, "#endregion", name))
        {
            selected = sb[];
            return true;
        }
        if (inRegion)
            sb ~= line;
    }
    selected = sb[];
    return found;
}

private bool markerNames(scope const(char)[] line, string marker, string name) @safe pure
{
    const at = line.indexOf(marker);
    if (at < 0)
        return false;
    auto rest = line[at + marker.length .. $];
    if (rest.length && rest[0] != ' ' && rest[0] != '\t')
        return false;
    rest = rest.strip;
    if (rest.endsWith("-->"))
        rest = rest[0 .. $ - 3].strip;
    if (rest.endsWith("*/"))
        rest = rest[0 .. $ - 2].strip;
    return rest == name;
}

// Lines `first` .. `last` (1-based, inclusive) of `content`.
private string selectLines(string content, long first, long last) @safe
{
    auto sb = appender!string;
    long n;
    foreach (line; content.lineSplitter!(KeepTerminator.yes))
    {
        n++;
        if (n >= first && n <= last)
            sb ~= line;
    }
    return sb[];
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // An in-memory tree, so the confinement tests never touch the disk.
    private string delegate(string) @system memoryReader(string[string] files)
    {
        return (string p) {
            if (auto f = p in files)
                return *f;
            throw new Exception("no such file");
        };
    }
}

@("include.expandIncludes.relativeRangeAndRegion")
@system unittest
{
    auto o = IncludeOptions(root: "/docs", read: memoryReader([
        "/docs/credits/parts/a.md": "### A\n\nprose\n",
        "/docs/credits/lic/A": "line1\nline2\nline3\n",
        "/docs/snip.d": "x\n// #region core\nint y;\n// #endregion core\nz\n",
    ]));
    const page = "# Credits\n\n<!-- @include: ./parts/a.md -->\n\n```text\n"
        ~ "<!-- @include: ./lic/A{2,} -->\n```\n<!-- @include: @/snip.d#core -->\n";
    const got = expandIncludes(page, "/docs/credits/index.md", o);
    assert(got == "# Credits\n\n### A\n\nprose\n\n```text\nline2\nline3\n```\nint y;\n", got);
}

@("include.expandIncludes.confinedAndTotal")
@system unittest
{
    auto o = IncludeOptions(root: "/docs", read: memoryReader([
        "/docs/self.md": "<!-- @include: ./self.md -->\n",
        "/etc/passwd": "root:x:0:0\n",
    ]));
    // Outside the root: refused, and nothing is read.
    auto got = expandIncludes("<!-- @include: ../etc/passwd -->\n", "/docs/x.md", o);
    assert(got.canFind("include error") && got.canFind("outside the source root")
        && !got.canFind("root:x"), got);
    // A cycle, a missing file and an unknown region are located errors.
    got = expandIncludes("<!-- @include: ./self.md -->\n", "/docs/x.md", o);
    assert(got.canFind("includes itself"), got);
    got = expandIncludes("a\n<!-- @include: ./gone.md -->\n", "/docs/x.md", o);
    assert(got.canFind("(/docs/x.md:2)") && got.canFind("cannot read"), got);
    got = expandIncludes("<!-- @include: ./self.md#nope -->\n", "/docs/x.md", o);
    assert(got.canFind("no region"), got);
    // A wider boundary admits the repository, still not beyond it.
    o.boundary = "/";
    got = expandIncludes("<!-- @include: ../etc/passwd -->\n", "/docs/x.md", o);
    assert(got.canFind("root:x"), got);
}

@("include.expandIncludes.untouchedWithoutDirectives")
@system unittest
{
    const page = "# Title\n\n<!-- a comment -->\n";
    assert(expandIncludes(page, "/docs/x.md", IncludeOptions(root: "/docs")) is page);
}

@("include.expandIncludes.assetPaths")
@system unittest
{
    // Android serves the credits from APK assets: a scheme-like prefix
    // resolves and confines like a directory.
    auto o = IncludeOptions(root: "asset:credits", read: memoryReader([
        "asset:credits/parts/a.md": "A\n",
    ]));
    assert(expandIncludes("<!-- @include: ./parts/a.md -->\n",
        "asset:credits/terminal.md", o) == "A\n");
    assert(expandIncludes("<!-- @include: ../../x -->\n",
        "asset:credits/terminal.md", o).canFind("outside the source root"));
}
