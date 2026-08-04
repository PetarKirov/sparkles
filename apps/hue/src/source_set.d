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
files, not a parallel mechanism — and recursive, `.gitignore`-aware descent is
deferred to the [file-tree explorer](../../../docs/specs/hue/tree-view.md) (`TVU1`).

Layered as $(B pure predicates + a thin I/O shell): $(LREF isRenderable),
$(LREF entryName) and the tally functions are `@safe pure` and unit-tested with no
filesystem, while $(LREF collectSources) is the one function that touches disk.
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
    string name;    /// display name, and the gallery page stem ($(LREF entryName))
    string summary; /// the one-line summary (`GAL8`)
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
Collects the renderable documents directly inside `dir` into a $(LREF SourceSet),
sorted by path, summarizing each ($(LREF twoslashTally) for a twoslash payload,
$(LREF plainTally) otherwise). Top-level only — recursive descent is `TVU1`.

The one function here that touches the filesystem. A file that cannot be read or
parsed still gets an entry, summarized as unreadable (`GAL8`); dropping it is the
gallery writer's call (`GAL9`).
*/
SourceSet collectSources(string dir, bool twoslash) @system
{
    import std.file : dirEntries, readText, SpanMode;

    string[] paths;
    foreach (e; dirEntries(dir, SpanMode.shallow))
        if (e.isFile && isRenderable(e.name, twoslash))
            paths ~= e.name;
    sort(paths);

    SourceEntry[] entries;
    foreach (p; paths)
        entries ~= SourceEntry(path: p, name: entryName(p, twoslash),
            summary: summarize(p, twoslash));
    return SourceSet(entries: entries);
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
