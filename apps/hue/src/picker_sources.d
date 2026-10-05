/** Incremental picker source seam and the `.gitignore`-aware files finder. */
module picker_sources;

import std.path : baseName, buildPath;

import sparkles.build_primitives.glob_walk : globWalkGitRepository;

import picker_grep : DocHandle;
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
    /// The document this names, when the source has one (`PKC3`). A files
    /// row leaves it null and is addressed by `path`; a grep row over a
    /// memory-only document has no path and is addressed ONLY by this.
    DocHandle handle;

    /// Whether this names anything at all. A finder returns
    /// `PickerTarget.init` for an index it cannot resolve, and a host must
    /// not act on it — the old seam signalled that with a null string,
    /// which is why the check is not `path is null` any more: a document
    /// that never touched the filesystem is still a valid target.
    bool valid() const @safe pure nothrow @nogc
        => path.length != 0 || handle.valid;
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

/// One row of a $(LREF ChoiceFinder): what the list shows and matches, the
/// value accepting it picks, and where the preview looks meanwhile.
struct Choice
{
    string label;        ///
    string value;        ///
    PickerTarget target; /// the declaration the preview shows
}

/**
A fixed list of values to pick one from (`PKS11`) — a short corpus a host
builds itself, such as the configurations a dub recipe declares. Rows keep
the order they are given in under the empty query.
*/
struct ChoiceFinder
{
    private Choice[] rows;
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

    /// Where the row at `index` points: its declaration, for the preview.
    PickerTarget resolve(size_t index) const @safe pure
        => index < rows.length ? rows[index].target : PickerTarget.init;

    /// The value the row at `index` picks; `null` past the end.
    string value(size_t index) const @safe pure nothrow @nogc
        => index < rows.length ? rows[index].value : null;

    size_t length() const @safe pure nothrow @nogc => candidates.length;
}

static assert(isFinder!ChoiceFinder);

/// Freezes `rows` into a $(LREF ChoiceFinder).
ChoiceFinder choiceFinder(Choice[] rows) @safe pure nothrow
{
    ChoiceFinder result;
    result.rows = rows;
    ulong corpusHigh = 0xcbf29ce484222325UL;
    ulong corpusLow = 0x84222325cbf29ce4UL;
    foreach (i, ref row; rows)
    {
        CandidateView candidate;
        candidate.id = stablePathId(row.label);
        candidate.path = row.label;
        candidate.pathFlavor = PathFlavor.unix;
        candidate.filenameOffset = 0;
        // The given order is the ranking under an empty query: the most
        // recent ranks first, so the first row is the most recent.
        candidate.recencyKey = cast(long) (rows.length - i);
        result.candidates ~= candidate;
        result.ranks ~= RankContext.init;
        corpusHigh = fnv1a(row.label, corpusHigh);
        corpusLow = fnv1a(row.value, corpusLow);
    }
    result.corpus = CorpusId(corpusHigh, corpusLow);
    return result;
}

@("picker.sources.choicesKeepTheirOrderAndValues")
@safe unittest
{
    auto f = choiceFinder([
        Choice("default", null, PickerTarget(path: "/r/dub.sdl")),
        Choice("gpu-effects", "gpu-effects", PickerTarget(path: "/r/dub.sdl", line: 40)),
    ]);
    assert(f.length == 2);
    const s = f.snapshot();
    assert(s.candidates[0].path == "default" && s.candidates[1].path == "gpu-effects");
    assert(s.candidates[0].recencyKey > s.candidates[1].recencyKey);
    assert(f.value(0) is null && f.value(1) == "gpu-effects");
    assert(f.resolve(1).line == 40);
    assert(!f.resolve(2).valid && f.value(2) is null);
}

/**
Walk `root` with nested `.gitignore` rules and freeze a files snapshot.

The walk is `globWalkGitRepository` — the repository's one glob-filtered
walk (`PKC4`), which the grep source will share. It used to be
`walkGitRepository` with a hand-rolled glob layer on top, and the two
layers did not agree: `.gitignore` was applied FIRST, so an `include` glob
could only rescue a file from `exclude`, never from being ignored.

The explorer's `XPF2` precedence — snacks' — is that `include` overrides
hidden, ignored AND exclude, which is what `GitGlobFilter` implements. So a
gitignored file matching an include glob appeared in the tree and not in
the picker, and the two panes disagreed about what the project contains.
*/
FilesFinder collectFilesFinder(string root,
    scope const(string)[] includeGlobs = null,
    scope const(string)[] excludeGlobs = null) @safe
{
    FilesFinder result;
    result.root = root;
    auto files = globWalkGitRepository(root, includeGlobs, excludeGlobs);
    ulong corpusHigh = fnv1a(root, 0xcbf29ce484222325UL);
    ulong corpusLow = fnv1a(root, 0x84222325cbf29ce4UL);
    while (!files.empty)
    {
        const relative = files.front;
        files.popFront();

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
    import sparkles.test_utils.tmpfs : TmpFS;

    auto fixture = TmpFS.create();
    const root = fixture.dir;
    fixture.writeFileAt(".gitignore", "build/\n*.tmp\n");
    fixture.writeFileAt("src/app.d", "void main() {}\n");
    fixture.writeFileAt("src/keep.log", "log\n");
    fixture.writeFileAt("drop.tmp", "tmp\n");
    fixture.writeFileAt("build/out.d", "int x;\n");

    auto finder = collectFilesFinder(root, ["keep.log"], ["*.log"]);
    assert(finder.length == 3); // .gitignore, app.d, explicitly included log
    auto snapshot = finder.snapshot();
    assert(snapshot.candidates.length == finder.length);
    foreach (candidate; snapshot.candidates)
        assert(candidate.path != "drop.tmp" && candidate.path != "build/out.d");

    // `XPF2`/snacks precedence: an `include` glob overrides `.gitignore`,
    // not merely `exclude`. `drop.tmp` is ignored by `*.tmp`, and naming it
    // explicitly brings it back — which is what the explorer has always
    // done, and what this finder did NOT do while it applied `.gitignore`
    // first and layered its own globs on the survivors. The two panes
    // disagreed about what the project contains (`PKC4`).
    auto rescued = collectFilesFinder(root, ["drop.tmp"], null);
    bool sawDrop;
    foreach (candidate; rescued.snapshot().candidates)
        if (candidate.path == "drop.tmp")
            sawDrop = true;
    assert(sawDrop, "an explicit include must override `.gitignore`");

    // And a directory `.gitignore` excludes stays excluded when nothing
    // includes it — an include re-admits what the walk reaches, it does not
    // force entry into an ignored directory.
    foreach (candidate; rescued.snapshot().candidates)
        assert(candidate.path != "build/out.d");
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
