/** Incremental picker source seam and the `.gitignore`-aware files finder. */
module picker_sources;

import std.path : baseName, buildPath, globMatch;

import sparkles.build_primitives : walkGitRepository;
import sparkles.fuzzy : CandidateId, CandidateSnapshot, CandidateView,
    CorpusId, PathFlavor, RankContext;

/**
Where accepting a row goes.

A path is not enough, and it is not always available. The grep source
addresses a **line and column inside a document** (`PKC3`), and a session's
documents need not exist on disk at all — `hue pr` builds them from a forge
payload and git-history browsing will build them from object content
(`SRC6`). So the target is a location, and `path` is the part of it that a
file-backed source happens to be able to fill in.

`line`/`column` are 1-based, matching every compiler diagnostic and
`PKQ4`'s `path:line:col` syntax; `0` means unspecified, so a files source
returns a target that names no position and the viewer keeps its scroll.
*/
struct PickerTarget
{
    /// Absolute path, or `null` when the target is not file-backed.
    string path;
    /// 1-based source line; `0` = unspecified.
    uint line;
    /// 1-based byte column; `0` = unspecified.
    uint column;

    /// Whether this names anything at all. A finder returns
    /// `PickerTarget.init` for an index it cannot resolve, and a host must
    /// not act on it — the old seam signalled that with a null string.
    bool valid() const @safe pure nothrow @nogc => path.length != 0;
}

/**
DbI contract for a picker finder.

A finder owns every path borrowed by its snapshot. `snapshot` stays immutable
until the scheduler has retired all generations that use it; `resolve` may
allocate because it runs only after accepting a row, never on a keystroke.
*/
enum bool isFinder(Finder) = is(typeof({
    Finder finder = Finder.init;
    CandidateSnapshot snapshot = finder.snapshot();
    PickerTarget target = finder.resolve(size_t.init);
}));

/// Immutable snapshot accessor shared by all conforming finder values.
CandidateSnapshot finderSnapshot(Finder)(ref Finder finder)
if (isFinder!Finder)
{
    return finder.snapshot();
}

/** One eagerly built files corpus. Construction is the I/O/allocation seam. */
struct FilesFinder
{
    string root;
    private string[] paths;
    private CandidateView[] candidates;
    private RankContext[] ranks;
    private CorpusId corpus;

    CandidateSnapshot snapshot() const @trusted pure nothrow @nogc
    {
        CandidateSnapshot result;
        result.id = corpus;
        result.candidates = candidates;
        result.rankContexts = ranks;
        return result;
    }

    /// Resolve a corpus row after the user accepts it. A file has no
    /// position of its own, so the target names none and the viewer keeps
    /// whatever scroll the document already had.
    PickerTarget resolve(size_t index) const @safe pure
    {
        if (index >= paths.length)
            return PickerTarget.init;
        return PickerTarget(path: buildPath(root, paths[index]));
    }

    size_t length() const @safe pure nothrow @nogc => candidates.length;
}

static assert(isFinder!FilesFinder);

/**
Walk `root` with nested `.gitignore` rules and freeze a files snapshot.

Include globs have the explorer's snacks-style precedence: an explicit include
keeps a file even when an exclude also matches. Both basename and root-relative
path are tested, matching the explorer pane.
*/
FilesFinder collectFilesFinder(string root,
    scope const(string)[] includeGlobs = null,
    scope const(string)[] excludeGlobs = null) @safe
{
    FilesFinder result;
    result.root = root;
    auto files = walkGitRepository(root);
    ulong corpusHigh = fnv1a(root, 0xcbf29ce484222325UL);
    ulong corpusLow = fnv1a(root, 0x84222325cbf29ce4UL);
    while (!files.empty)
    {
        const relative = files.front;
        files.popFront();
        const name = relative.baseName;
        const explicitlyIncluded = matchesAny(name, relative, includeGlobs);
        if (!explicitlyIncluded
            && matchesAny(name, relative, excludeGlobs))
            continue;

        result.paths ~= relative;
        CandidateView candidate;
        candidate.id = stablePathId(relative);
        candidate.path = result.paths[$ - 1];
        candidate.pathFlavor = PathFlavor.unix;
        candidate.filenameOffset = filenameOffset(candidate.path);
        // Discovery order is not a ranking signal. Real recency is supplied
        // explicitly by the history adapter; cold files tie-break by stable ID.
        candidate.recencyKey = 0;
        result.candidates ~= candidate;
        result.ranks ~= RankContext.init;
        corpusHigh = fnv1a(relative, corpusHigh);
        corpusLow = fnv1a(relative, corpusLow);
    }
    result.corpus = CorpusId(corpusHigh, corpusLow);
    return result;
}

private bool matchesAny(scope const(char)[] name, scope const(char)[] path,
    scope const(string)[] patterns) @safe
{
    foreach (pattern; patterns)
        if (globMatch(name, pattern) || globMatch(path, pattern))
            return true;
    return false;
}

private CandidateId stablePathId(scope const(char)[] path)
    @safe pure nothrow @nogc
{
    return CandidateId(
        fnv1a(path, 0xcbf29ce484222325UL),
        fnv1a(path, 0x84222325cbf29ce4UL));
}

private ulong fnv1a(scope const(char)[] bytes, ulong seed)
    @safe pure nothrow @nogc
{
    auto result = seed;
    foreach (value; bytes)
    {
        result ^= cast(ubyte) value;
        result *= 0x100000001b3UL;
    }
    return result;
}

private size_t filenameOffset(scope const(char)[] path)
    @safe pure nothrow @nogc
{
    size_t result;
    foreach (i, value; path)
        if (value == '/')
            result = i + 1;
    return result;
}

@("picker.sources.filesHonorGitignoreAndGlobs")
@system
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "hue-picker-files-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "src"));
    mkdirRecurse(buildPath(root, "build"));
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, ".gitignore"), "build/\n*.tmp\n");
    write(buildPath(root, "src", "app.d"), "void main() {}\n");
    write(buildPath(root, "src", "keep.log"), "log\n");
    write(buildPath(root, "drop.tmp"), "tmp\n");
    write(buildPath(root, "build", "out.d"), "int x;\n");

    auto finder = collectFilesFinder(root, ["keep.log"], ["*.log"]);
    assert(finder.length == 3); // .gitignore, app.d, explicitly included log
    auto snapshot = finder.snapshot();
    assert(snapshot.candidates.length == finder.length);
    foreach (candidate; snapshot.candidates)
        assert(candidate.path != "drop.tmp" && candidate.path != "build/out.d");
}

@("picker_sources.PickerTarget.filesResolveNamesNoPosition")
@safe pure nothrow @nogc
unittest
{
    // A file has no position of its own. `line`/`column` stay 0 so a host
    // can tell "open this document" from "open it AT a place" — the
    // distinction the grep source exists to make (`PKC3`), and one a bare
    // path could not carry.
    assert(PickerTarget.init.line == 0 && PickerTarget.init.column == 0);
    assert(!PickerTarget.init.valid, "an unresolvable row names nothing");
    assert(PickerTarget(path: "/a/b.d").valid);
    assert(PickerTarget(path: "/a/b.d").line == 0,
        "a files row must not claim a line it does not know");
    assert(PickerTarget(path: "/a/b.d", line: 12, column: 3).line == 12);
}
