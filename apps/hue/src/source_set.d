/**
The **document set** ([`SRC5`/`SRC6`](../../../docs/specs/hue/feature-requirements.md),
[`gallery.md` `GAL1`](../../../docs/specs/hue/gallery.md)) — hue's model of "more
than one file".

A directory target resolves to an ordered, filtered list of renderable files, each
carrying a display name and a one-line summary ($(LREF twoslashTally) /
$(LREF plainTally)). That single list is what every mode consumes: the static HTML
gallery iterates it, and the interactive backends navigate it — a set is acquired
once and rendered many ways.

The shape is deliberately thin. It is the substrate the planned
[tab view](../../../docs/specs/hue/tab-view.md) (`TBU1`) turns into tabs and the
planned [navigation](../../../docs/specs/hue/navigation.md) (`LNK3`) reuses to open
files, not a parallel mechanism.

A set is either $(B one directory deep) or the whole $(B subtree)
(`collectSources(recursive: true)`, `SRC9`). The recursive arm does not walk the
tree itself: it drives `sparkles:build-primitives`' `walkGitRepository`, so
`.gitignore` (nested and ancestor scopes) and `.git/` exclusion come from the
library that already implements them rather than from a skip-list here.

Layered as $(B pure predicates + a thin I/O shell): $(LREF isRenderable),
$(LREF entryName), $(LREF entryRelPath) and the tally functions are `@safe pure`
and unit-tested with no filesystem, while $(LREF collectSources) is the one
function that touches disk.
*/
module source_set;

import std.algorithm.sorting : sort;
import std.conv : text, to;
import std.path : baseName, extension;
import std.string : chompPrefix, endsWith;

import sparkles.syntax : canonicalLanguage, canonicalLanguageOfPath;
import sparkles.twoslash : Node, NodeType;

/// One document in a $(LREF SourceSet).
struct SourceEntry
{
    string path;    /// the file to read (as given on the command line)
    string name;    /// display name, and the page header ($(LREF entryName))
    string summary; /// the one-line summary (`GAL8`)

    /**
    The entry's place in the set's directory structure: its path relative to
    the mirroring root, with a twoslash payload's suffix dropped
    ($(LREF entryRelPath)) — `src/app.d`, `01-hover`. For a one-directory-deep
    set this is just $(D name), which is why the flat gallery's layout is
    unchanged by mirroring (`GAL12`).
    */
    string relPath;

    /// The page's path under the gallery's output directory —
    /// $(D relPath ~ ".html"), so the output tree mirrors the source tree.
    string outPath;
}

/**
An ordered set of documents plus the currently-selected one. Construct with
$(LREF collectSources); navigate with $(LREF SourceSet.move).
*/
struct SourceSet
{
    SourceEntry[] entries;
    size_t index; /// the selected entry (always < `entries.length` when non-empty)

@safe pure nothrow @nogc:

    /// `true` when the set holds no documents.
    bool empty() const scope => entries.length == 0;

    /// The number of documents.
    size_t length() const scope => entries.length;

    /// The selected document.
    ref const(SourceEntry) current() const return scope
    in (!empty)
        => entries[index];

    /// `true` iff a previous/next document exists (the gallery renders the
    /// corresponding nav link disabled rather than omitting it — `GAL3`).
    bool hasPrev() const scope => !empty && index > 0;
    /// ditto
    bool hasNext() const scope => !empty && index + 1 < entries.length;

    /**
    Moves the selection by `delta`, clamping at both ends (no wraparound, so the
    interactive backends agree with the gallery's disabled end links). Returns
    `true` iff the selection actually changed.
    */
    bool move(int delta) scope
    {
        if (empty)
            return false;
        const long want = cast(long) index + delta;
        const size_t clamped = want < 0 ? 0
            : (want >= cast(long) entries.length ? entries.length - 1 : cast(size_t) want);
        const changed = clamped != index;
        index = clamped;
        return changed;
    }
}

/// The `.twoslash.json` double extension a twoslash payload carries.
private enum twoslashSuffix = ".twoslash.json";

/**
Extensions that are certainly $(B not) text. The filter is a deny-list rather than
an allow-list because hue renders any text file, degrading to plain text when no
grammar claims the extension (`DEG`) — `canonicalLanguage` normalizes a label but
does not decide membership, so an allow-list would silently drop the `.toml` /
`.txt` / `.ini` files a directory legitimately contains. This list only has to
cover what would render as garbage.
*/
private immutable string[] binaryExtensions = [
    // images
    "png", "jpg", "jpeg", "gif", "bmp", "ico", "webp", "avif", "tiff", "psd",
    // fonts
    "ttf", "otf", "woff", "woff2", "eot",
    // archives & packages
    "zip", "gz", "bz2", "xz", "zst", "tar", "7z", "rar", "jar", "whl", "deb", "rpm",
    // executables, objects & libraries
    "exe", "dll", "so", "dylib", "o", "obj", "a", "lib", "wasm", "class", "pyc",
    // media
    "mp3", "mp4", "wav", "ogg", "flac", "avi", "mkv", "mov", "webm",
    // documents & databases
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "sqlite", "db", "bin",
];

/**
Extensionless base names that are certainly text. This branch has to be an
allow-list — the opposite of $(LREF binaryExtensions) — because an extensionless
file carries no evidence at all: `Makefile` and the stripped ELF a build
directory holds look identical from the path. Naming the ones worth rendering is
the only honest filter, so the list covers the conventional extensionless files a
source tree actually contains (`LNG3`).
*/
private immutable string[] textualBasenames = [
    // build & container recipes
    "makefile", "gnumakefile", "justfile", "dockerfile", "containerfile",
    "rakefile", "gemfile", "brewfile", "procfile", "vagrantfile", "cakefile",
    // repository boilerplate
    "license", "licence", "copying", "notice", "authors", "contributors",
    "readme", "changelog", "changes", "news", "todo", "install", "version",
    "codeowners", "owners",
];

/**
`true` iff `path` is a document this set renders: a twoslash payload under
`twoslash`, else any file with an extension that is not obviously binary
($(LREF binaryExtensions)), or an extensionless file whose base name is
conventionally text ($(LREF textualBasenames)).

The two branches point opposite ways on purpose: an extension is evidence, so it
is filtered by deny-list (hue renders unknown text as plain text, `DEG2`); a bare
name is not, so it is filtered by allow-list.
*/
bool isRenderable(scope const(char)[] path, bool twoslash) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    if (twoslash)
        return path.endsWith(twoslashSuffix);

    const base = path.baseName;
    if (base.extension.length == 0)
        return textualBasenames.canFind!sameAsciiCaseless(base);

    const ext = canonicalLanguage(base.extension.chompPrefix("."));
    return ext.length != 0 && !binaryExtensions.canFind(ext);
}

/// ASCII case-insensitive equality — enough for `LICENSE` / `Makefile`, and
/// unlike `std.uni.toLower` it neither allocates nor throws, so the predicate
/// above keeps `@safe pure nothrow`.
private bool sameAsciiCaseless(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    static char lower(char c) @safe pure nothrow @nogc
        => c >= 'A' && c <= 'Z' ? cast(char)(c + ('a' - 'A')) : c;

    if (a.length != b.length)
        return false;
    foreach (i, char c; a)
        if (lower(c) != lower(b[i]))
            return false;
    return true;
}

/**
The display name (and gallery page stem) for `path`: a twoslash payload drops its
whole `.twoslash.json` suffix (`01-hover.twoslash.json` → `01-hover`), while a
plain source file $(B keeps) its extension (`app.d`), so `foo.d` and `foo.md`
cannot collide on one page name.
*/
string entryName(scope const(char)[] path, bool twoslash) @safe pure
{
    const base = path.baseName;
    if (twoslash && base.endsWith(twoslashSuffix))
        return base[0 .. $ - twoslashSuffix.length].idup;
    return base.idup;
}

/**
The set-relative **page path** for a document at root-relative `rel`: the same
path with a twoslash payload's whole `.twoslash.json` suffix dropped
(`fixtures/01-hover.twoslash.json` → `fixtures/01-hover`), a plain source file's
extension $(B kept) (`src/app.d`) — $(LREF entryName) generalized from the base
name to the whole path, so `a/app.d` and `b/app.d` cannot collide on one page
(`GAL12`).

Always `/`-separated: it is a URL path as much as a file path (the gallery
resolves inter-page links against it).
*/
string entryRelPath(scope const(char)[] rel, bool twoslash) @safe pure
{
    if (twoslash && rel.endsWith(twoslashSuffix))
        return rel[0 .. $ - twoslashSuffix.length].idup;
    return rel.idup;
}

/**
`true` iff a document at root-relative `rel` passes the `--include`/`--exclude`
globs, with the explorer's precedence ([`XPF2`](../../../docs/specs/hue/tree-view.md)):
an `include` match wins over everything, otherwise an `exclude` match drops the
entry. Each glob is matched against both the base name and the root-relative
path, so `*.d` and `src/*.d` both work.
*/
bool passesGlobs(scope const(char)[] rel, scope const(string)[] include,
    scope const(string)[] exclude) @safe
{
    if (include.length && globAny(rel, include))
        return true;
    return !(exclude.length && globAny(rel, exclude));
}

/// `true` iff any of `globs` matches `rel` or its base name (the explorer's
/// `globAny`, over the one path shape this module carries).
private bool globAny(scope const(char)[] rel, scope const(string)[] globs) @safe
{
    import std.path : globMatch;

    foreach (g; globs)
        if (globMatch(rel, g) || globMatch(rel.baseName, g))
            return true;
    return false;
}

/**
The node-kind **tally** of a twoslash payload (`GAL8`) — each kind once, suffixed
`×n` when it repeats, in first-seen order: `"hover×2 query"`. An empty node list
tallies as `"no nodes"` (an honest summary, not an empty cell).
*/
string twoslashTally(scope const Node[] nodes) @safe pure
{
    if (nodes.length == 0)
        return "no nodes";

    size_t[NodeType.max + 1] counts;
    NodeType[] order;
    foreach (ref const n; nodes)
    {
        if (counts[cast(size_t) n.type] == 0)
            order ~= n.type;
        ++counts[cast(size_t) n.type];
    }

    string outp;
    foreach (i, k; order)
    {
        if (i)
            outp ~= " ";
        const c = counts[cast(size_t) k];
        outp ~= c > 1 ? text(k, "×", c) : k.to!string;
    }
    return outp;
}

/**
The summary of a plain source file (`GAL8`): its language (or `text` when no
grammar claims the extension) and its physical line count.
*/
string plainTally(scope const(char)[] path, scope const(char)[] source) @safe pure
{
    const lang = canonicalLanguageOfPath(path);
    const n = lineCount(source);
    return text(lang.length ? lang : "text", " · ", n, n == 1 ? " line" : " lines");
}

/// Physical lines in `source` — newline-terminated and unterminated last lines
/// both count once; empty source has no lines.
private size_t lineCount(scope const(char)[] source) @safe pure nothrow @nogc
{
    if (source.length == 0)
        return 0;
    size_t n;
    foreach (char c; source)
        if (c == '\n')
            ++n;
    return source[$ - 1] == '\n' ? n : n + 1;
}

/**
Collects the renderable documents in `dir` into a $(LREF SourceSet), sorted by
path, summarizing each ($(LREF twoslashTally) for a twoslash payload,
$(LREF plainTally) otherwise).

`recursive` selects the whole subtree instead of just `dir`'s own entries
(`SRC9`); the descent is `walkGitRepository`'s, so `.gitignore` (the walk root's,
every nested one, and the enclosing repository's ancestor scopes) and `.git/` are
excluded by the library rather than re-decided here. `root` is the directory the
entries' $(D relPath)s — and therefore the mirrored output tree — are relative
to; it defaults to `dir`. `include`/`exclude` are the `--include`/`--exclude`
globs ($(LREF passesGlobs)); an `include` glob also re-admits a file
`.gitignore` excluded, matching the flag's explorer meaning. (An ignored
$(I directory) is still not descended: the walker's scope stack owns entering,
and a set is not worth unbalancing it for.)

The one function here that touches the filesystem. A file that cannot be read or
parsed still gets an entry, summarized as unreadable (`GAL8`); dropping it is the
gallery writer's call (`GAL9`).
*/
SourceSet collectSources(string dir, bool twoslash, bool recursive = false,
    string root = null, scope const(string)[] include = null,
    scope const(string)[] exclude = null) @system
{
    // (path on disk, path relative to the mirroring root) pairs, sorted by the
    // former — the set's order is the source tree's order, and stripping a
    // twoslash suffix must not reshuffle it.
    static struct Found { string path; string rel; }

    const prefix = mirrorPrefix(dir, root);
    Found[] found;

    void take(string path, const(char)[] walkRel)
    {
        found ~= Found(path, joinRel(prefix, walkRel));
    }

    if (recursive)
    {
        import std.path : buildPath;

        foreach (rel; walkSubtree(dir, include, exclude))
            if (isRenderable(rel, twoslash))
                take(buildPath(dir, rel), rel);
    }
    else
    {
        import std.file : dirEntries, SpanMode;

        foreach (e; dirEntries(dir, SpanMode.shallow))
        {
            const base = e.name.baseName;
            if (e.isFile && isRenderable(e.name, twoslash)
                && passesGlobs(base, include, exclude))
                take(e.name, base);
        }
    }
    found.sort!((a, b) => a.path < b.path);

    SourceEntry[] entries;
    foreach (ref f; found)
    {
        const rel = entryRelPath(f.rel, twoslash);
        entries ~= SourceEntry(path: f.path, name: entryName(f.path, twoslash),
            summary: summarize(f.path, twoslash), relPath: rel,
            outPath: rel ~ ".html");
    }
    return SourceSet(entries: entries);
}

/// The subtree of `dir` as root-relative `/`-separated paths, `.gitignore`- and
/// `.git`-filtered by `sparkles:build-primitives` and glob-filtered by
/// $(LREF GalleryWalkFilter).
private string[] walkSubtree(string dir, scope const(string)[] include,
    scope const(string)[] exclude) @system
{
    import std.array : array;

    import sparkles.build_primitives.dir_walk : dirEntriesFilter,
        GitRepositoryFilter, repositoryGitIgnoreStack;

    auto filter = GalleryWalkFilter(
        git: GitRepositoryFilter(dir, repositoryGitIgnoreStack(dir)),
        include: include.dup,
        exclude: exclude.dup);
    return dirEntriesFilter(dir, filter).array;
}

/**
The walker hook: `GitRepositoryFilter`'s `.gitignore` verdict, then the
`--include`/`--exclude` globs on top of it.

Entering directories is delegated verbatim — the filter's scope stack pushes on
`enterDir` and pops on `leaveDir`, so short-circuiting either would unbalance it.
*/
private struct GalleryWalkFilter
{
    import sparkles.build_primitives.dir_walk : GitRepositoryFilter;

    GitRepositoryFilter git;
    const(string)[] include;
    const(string)[] exclude;

    bool enterDir(const(char)[] rel) @safe => git.enterDir(rel);

    void leaveDir(const(char)[] rel) @safe pure { git.leaveDir(rel); }

    bool includeFile(const(char)[] rel) @safe
    {
        // `--include` overrides `.gitignore` (its documented meaning), but never
        // `.git/` itself: repository metadata is not a document.
        if (include.length && globAny(rel, include))
            return !isGitPath(rel);
        return git.includeFile(rel) && passesGlobs(rel, null, exclude);
    }
}

/// `true` iff `rel` is inside the repository's `.git` directory.
private bool isGitPath(scope const(char)[] rel) @safe pure nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    return rel == ".git" || rel.startsWith(".git/");
}

/**
The prefix a walk of `dir` contributes to a $(D relPath) when the mirroring
`root` is an ancestor of `dir` — `""` when `root` is empty or is `dir` itself,
and `""` again when `dir` does not lie under `root` (a mirrored tree cannot
contain `..`, so an unrelated root degrades to mirroring `dir`).
*/
private string mirrorPrefix(string dir, string root) @system
{
    import std.algorithm.searching : startsWith;
    import std.path : absolutePath, buildNormalizedPath, relativePath;

    if (root.length == 0)
        return null;
    const absDir = dir.absolutePath.buildNormalizedPath;
    const absRoot = root.absolutePath.buildNormalizedPath;
    if (absDir == absRoot)
        return null;
    const rel = relativePath(absDir, absRoot);
    return rel.startsWith("..") ? null : slashed(rel);
}

/// `path` with the platform's separators normalized to `/` (a $(D relPath) is a
/// URL path too).
private string slashed(string path) @safe pure nothrow
{
    version (Windows)
    {
        import std.string : replace;

        return path.replace("\\", "/");
    }
    else
        return path;
}

/// `prefix/rel`, tolerating an empty prefix.
private string joinRel(string prefix, scope const(char)[] rel) @safe pure nothrow
{
    if (prefix.length == 0)
        return rel.idup;
    return prefix ~ "/" ~ rel;
}

/// One entry's summary, degrading to a reported reason rather than throwing.
private string summarize(string path, bool twoslash) @system
{
    import std.file : readText;

    if (twoslash)
    {
        import sparkles.twoslash : loadTwoslashFile;

        auto res = loadTwoslashFile(path);
        return res.hasError ? "unreadable" : twoslashTally(res.value.nodes);
    }
    try
        return plainTally(path, readText(path));
    catch (Exception)
        return "unreadable";
}

// ---------------------------------------------------------------------------

@("source_set.isRenderable.twoslashAndPlain")
@safe pure nothrow
unittest
{
    // Twoslash mode takes only the double-extension payloads.
    assert(isRenderable("fixtures/01-hover.twoslash.json", true));
    assert(!isRenderable("fixtures/notes.json", true));
    assert(!isRenderable("fixtures/app.d", true));

    // Plain mode takes any text file — including extensions no grammar claims
    // (hue degrades those to plain text), but not binaries.
    assert(isRenderable("src/app.d", false));
    assert(isRenderable("README.md", false));
    assert(isRenderable("config.toml", false));  // no grammar, still text
    assert(!isRenderable("logo.png", false));    // binary
    assert(!isRenderable("dist/app.WASM", false)); // deny-list is case-insensitive

    // Extensionless files are allow-listed by base name (`LNG3`): a
    // conventional text file is rendered, anything else stays out, because a
    // bare name is exactly as consistent with a stripped binary.
    assert(isRenderable("Makefile", false));
    assert(isRenderable("nix/Dockerfile", false));
    assert(isRenderable("LICENSE", false));
    assert(isRenderable("license", false));      // match is case-insensitive
    assert(!isRenderable("build/hue", false));   // could be the linked binary
}

@("source_set.entryName.stemAndCollisions")
@safe pure
unittest
{
    // A twoslash payload drops the whole double extension (the mjs page stem).
    assert(entryName("fixtures/01-hover.twoslash.json", true) == "01-hover");
    // A plain file keeps its extension, so same-stem files stay distinct.
    assert(entryName("src/app.d", false) == "app.d");
    assert(entryName("src/app.md", false) == "app.md");
    assert(entryName("app.d", false) != entryName("app.md", false));
}

@("source_set.entryRelPath.mirrorsThePathNotJustTheName")
@safe pure
unittest
{
    // A plain file keeps its whole relative path (extension included), so two
    // same-named files in different directories get different pages (`GAL12`).
    assert(entryRelPath("src/app.d", false) == "src/app.d");
    assert(entryRelPath("a/app.d", false) != entryRelPath("b/app.d", false));
    // A twoslash payload drops the double extension, keeping its directory.
    assert(entryRelPath("f/01-hover.twoslash.json", true) == "f/01-hover");
    // A top-level file's relative path IS its name — the flat layout is the
    // depth-0 case of the mirrored one.
    assert(entryRelPath("app.d", false) == entryName("app.d", false));
}

@("source_set.passesGlobs.includeWinsOverExclude")
@safe
unittest
{
    // No globs: everything passes.
    assert(passesGlobs("src/app.d", null, null));
    // `exclude` drops, matched against the base name or the whole path.
    assert(!passesGlobs("src/app.d", null, ["*.d"]));
    assert(!passesGlobs("src/app.d", null, ["src/*"]));
    assert(passesGlobs("src/app.md", null, ["*.d"]));
    // `include` wins over `exclude` (the explorer's precedence), and does not
    // itself restrict what an empty `exclude` already admits.
    assert(passesGlobs("src/app.d", ["app.d"], ["*.d"]));
    assert(passesGlobs("src/app.d", ["*.md"], null));
}

@("source_set.twoslashTally.countsInFirstSeenOrder")
@safe pure
unittest
{
    const nodes = [
        Node(type: NodeType.hover),
        Node(type: NodeType.query),
        Node(type: NodeType.hover),
    ];
    // First-seen order, `×n` only when repeated — the JS harness's format.
    assert(twoslashTally(nodes) == "hover×2 query");
    assert(twoslashTally([Node(type: NodeType.error)]) == "error");
    assert(twoslashTally([]) == "no nodes");
}

@("source_set.plainTally.languageAndLines")
@safe pure
unittest
{
    assert(plainTally("a.d", "void main() {}\n") == "d · 1 line");
    assert(plainTally("a.d", "one\ntwo\n") == "d · 2 lines");
    // An unterminated last line still counts.
    assert(plainTally("a.d", "one\ntwo") == "d · 2 lines");
    // The label is normalized (`md` → `markdown`); empty source has no lines.
    assert(plainTally("README.md", "x\n") == "markdown · 1 line");
    assert(plainTally("empty.d", "") == "d · 0 lines");
    // An extensionless path names its language through its base name (`LNG3`).
    assert(plainTally("Makefile", "all:\n") == "make · 1 line");
    // …and one no alias claims still degrades to a named plain-text tally.
    assert(plainTally("LICENSE", "MIT\n") == "license · 1 line");
}

version (unittest)
{
    /// A throwaway source tree: `dirs` are created, `files` are `path → text`
    /// pairs written under `root`. Returns the root (deleted by the caller).
    private string makeTree(string tag, scope const(string[2])[] files) @system
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.path : buildPath, dirName;
        import std.uuid : randomUUID;

        const root = buildPath(tempDir(), "hue-" ~ tag ~ "-" ~ randomUUID.toString);
        foreach (ref f; files)
        {
            const path = buildPath(root, f[0]);
            mkdirRecurse(path.dirName);
            write(path, f[1]);
        }
        return root;
    }
}

/// The recursive set descends the subtree, mirrors each file's path, and leaves
/// `.gitignore`d files and `.git/` out — the walker's job, not a skip-list here
/// (`SRC9`).
@("source_set.collectSources.recursiveHonoursGitignore")
@system
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.file : rmdirRecurse;

    const root = makeTree("recursive", [
        [".gitignore", "build/\n*.tmp\n"],
        ["top.d", "module top;\n"],
        ["src/app.d", "module app;\n"],
        ["src/deep/notes.md", "# notes\n"],
        ["src/scratch.tmp", "ignored\n"],
        ["build/out.d", "ignored\n"],
        [".git/config", "[core]\n"],
    ]);
    scope (exit)
        rmdirRecurse(root);

    // Top level only: the subtree is invisible, as before (`SRC5`).
    assert(collectSources(root, false).entries.map!(e => e.relPath).array == ["top.d"]);

    auto set = collectSources(root, false, recursive: true);
    assert(set.entries.map!(e => e.relPath).array
        == ["src/app.d", "src/deep/notes.md", "top.d"], set.entries[0].relPath);
    // Every page path mirrors its source path.
    assert(set.entries.map!(e => e.outPath).array
        == ["src/app.d.html", "src/deep/notes.md.html", "top.d.html"]);
    // `name` stays the base name (the page header), and the summaries are real.
    assert(set.entries[0].name == "app.d");
    assert(set.entries[0].summary == "d · 1 line");

    // `--exclude` drops, `--include` re-admits a `.gitignore`d file.
    auto excluded = collectSources(root, false, recursive: true, null, null, ["*.md"]);
    assert(excluded.entries.map!(e => e.relPath).array == ["src/app.d", "top.d"]);
    auto included = collectSources(root, false, recursive: true, null, ["*.tmp"]);
    assert(included.entries.map!(e => e.relPath).array
        == ["src/app.d", "src/deep/notes.md", "src/scratch.tmp", "top.d"]);
}

/// Two same-named files in different directories are two entries with two
/// distinct page paths — the flat layout's collision (`GAL12`).
@("source_set.collectSources.sameNamedFilesDoNotCollide")
@system
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.file : rmdirRecurse;

    const root = makeTree("collision", [
        ["foo/app.d", "module foo;\n"],
        ["bar/app.d", "module bar;\n"],
    ]);
    scope (exit)
        rmdirRecurse(root);

    auto set = collectSources(root, false, recursive: true);
    assert(set.length == 2);
    // Same display name…
    assert(set.entries[0].name == set.entries[1].name);
    // …different pages.
    assert(set.entries.map!(e => e.outPath).array == ["bar/app.d.html", "foo/app.d.html"]);
}

/// `root` re-bases the mirrored paths on an ancestor of the walked directory, so
/// a gallery can be mounted where the caller's tree expects it. A `root` that is
/// not an ancestor degrades to mirroring the target itself (a mirrored tree
/// cannot contain `..`).
@("source_set.collectSources.rootRebasesRelativePaths")
@system
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    const root = makeTree("root-rebase", [["libs/base/a.d", "module a;\n"]]);
    scope (exit)
        rmdirRecurse(root);

    const target = buildPath(root, "libs", "base");
    assert(collectSources(target, false, recursive: true, root).entries
        .map!(e => e.relPath).array == ["libs/base/a.d"]);
    assert(collectSources(target, false, recursive: true, target).entries
        .map!(e => e.relPath).array == ["a.d"]);
    assert(collectSources(target, false, recursive: true, buildPath(root, "elsewhere"))
        .entries.map!(e => e.relPath).array == ["a.d"]);
}

@("source_set.move.clampsAtBothEnds")
@safe pure nothrow
unittest
{
    auto set = SourceSet(entries: [
        SourceEntry(name: "a"), SourceEntry(name: "b"), SourceEntry(name: "c"),
    ]);
    assert(set.length == 3 && !set.empty);
    assert(!set.hasPrev && set.hasNext);
    assert(set.current.name == "a");

    assert(set.move(1) && set.index == 1);
    assert(set.hasPrev && set.hasNext);
    assert(set.move(1) && set.current.name == "c");

    // Clamped at the end: no change, and `move` reports it.
    assert(!set.move(1) && set.index == 2);
    assert(set.hasPrev && !set.hasNext);

    assert(set.move(-2) && set.index == 0);
    assert(!set.move(-1) && set.index == 0);

    // An empty set never moves.
    SourceSet none;
    assert(none.empty && !none.move(1) && !none.hasPrev && !none.hasNext);
}
