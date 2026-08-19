// Finding the coverage artifact for an open file, so `hue view foo.d` lights up
// its gutter the way `--live-types` lights up hovers — without the reader having
// to know where `-cov` put its listings or what it called them.
//
// `ci --test` merges every sub-package's run into `<repo>/build/coverage`, and
// that convention is the whole contract here: one directory, one truthful entry
// per file (`COV4`).
//
// Two things make this less obvious than a path join.
//
// A listing's *name* is its source path with `/` replaced by `-`, which cannot
// be inverted — `libs-test-runner-impl-src-…` could be `libs/test-runner-impl/…`
// or `libs/test/runner/impl/…`, and only the first is real. The name also
// encodes the path as the compiler saw it, so a build run from a sub-directory
// writes `src/sparkles/math/vector.lst` where one run from the root writes
// `libs-math-src-sparkles-math-vector.lst`. So the mapping is built the other
// way round: read each artifact's trailer, which carries the path intact.
//
// And an artifact older than the file it describes is not merely stale, it is
// wrong — its line numbers refer to text that has since moved. That case warns
// and attaches nothing.
module coverage_discovery;

import std.file : DirEntry, dirEntries, exists, isDir, isFile, SpanMode, timeLastModified;
import std.path : absolutePath, buildPath, dirName;

import sparkles.base.logger : info;
import sparkles.code_instrumentation : dmdListingSource;

/// Where `ci --test` leaves its merged listings, relative to the repository root.
enum coverageDirName = buildPath("build", "coverage");

/// One artifact and the source it describes.
struct CoverageEntry
{
    string artifact;   /// the `.lst` path
    string source;     /// the path its trailer names, as the compiler saw it
}

/**
The repository root at or above `start`, found by the `.git` it contains.

Params:
    start = a path inside the repository (a file or a directory)

Returns: the root, or `null` when `start` is not inside a repository.
*/
string repositoryRoot(string start) @safe
{
    if (start.length == 0)
        return null;

    string dir = start.absolutePath;
    if (!(dir.exists && dir.isDir))
        dir = dir.dirName;

    // `.git` is a directory in a normal clone and a *file* in a worktree, so
    // test for existence rather than for a directory — hue is developed in
    // worktrees, where the stricter test finds nothing.
    while (true)
    {
        if (buildPath(dir, ".git").exists)
            return dir;
        const parent = dir.dirName;
        if (parent == dir)
            return null;
        dir = parent;
    }
}

/**
Indexes every listing in `dir` by the source its trailer names.

Only the trailer is read, not the counter columns: a repository-wide run leaves
hundreds of listings and parsing each in full to recover one line would cost
more than the overlay saves.

Params:
    dir = the directory holding `.lst` artifacts

Returns: one entry per listing that names a source; artifacts that name nothing
    (a truncated run, a stray file) are skipped rather than reported, since a
    directory of build output is not a place to raise errors from.
*/
CoverageEntry[] indexListings(string dir) @safe
{
    import std.file : readText;

    CoverageEntry[] entries;
    if (!(dir.exists && dir.isDir))
        return entries;

    foreach (DirEntry entry; (() @trusted => dirEntries(dir, "*.lst", SpanMode.shallow))())
    {
        string text;
        try
            text = entry.name.readText;
        catch (Exception)
            continue;   // unreadable mid-build, or not text at all
        const source = dmdListingSource(text);
        if (source.length)
            entries ~= CoverageEntry(entry.name, source);
    }
    return entries;
}

/**
The entry describing `sourcePath`, or `null` when none does.

Matching is by whole path components from the right, because the two paths
rarely agree on their left: a listing may say `libs/math/src/sparkles/math/vector.d`
for a file opened as `/abs/repo/libs/math/src/sparkles/math/vector.d`, or say
`src/sparkles/math/vector.d` when the run happened inside the package.

The *longest* match wins. First-wins would be a real defect here rather than a
detail: this repository has a `package.d` in almost every library, and any of
them is a suffix match for a one-component comparison.

Params:
    entries = the index
    sourcePath = the opened file

Returns: a pointer into `entries`, or `null`.
*/
const(CoverageEntry)* bestMatch(return scope const CoverageEntry[] entries,
    scope const(char)[] sourcePath) @safe pure nothrow @nogc
{
    const(CoverageEntry)* best;
    size_t bestLength;
    foreach (i; 0 .. entries.length)
    {
        const shared_ = sharedSuffixComponents(entries[i].source, sourcePath);
        if (shared_ > bestLength)
        {
            bestLength = shared_;
            best = &entries[i];
        }
    }
    return best;
}

/// How many whole path components `a` and `b` share, counted from the right;
/// `0` when the final components differ, which is the "unrelated files" answer.
private size_t sharedSuffixComponents(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    size_t count;
    size_t ai = a.length, bi = b.length;
    while (ai > 0 && bi > 0)
    {
        const aStart = lastSeparator(a[0 .. ai]);
        const bStart = lastSeparator(b[0 .. bi]);
        if (a[aStart .. ai] != b[bStart .. bi])
            return count;
        count++;
        ai = aStart == 0 ? 0 : aStart - 1;
        bi = bStart == 0 ? 0 : bStart - 1;
    }
    return count;
}

/// The index just past the last separator in `s`, i.e. where its final
/// component starts.
private size_t lastSeparator(scope const(char)[] s) @safe pure nothrow @nogc
{
    foreach_reverse (i, c; s)
        if (c == '/' || c == '\\')
            return i + 1;
    return 0;
}

/**
The coverage artifact for `sourcePath`, or `null` when there is nothing to
attach.

Params:
    sourcePath = the file being opened

Returns: the `.lst` path to hand to the overlay.
*/
string findCoverageArtifact(string sourcePath) @safe
{
    const root = repositoryRoot(sourcePath);
    if (root is null)
        return null;

    const dir = buildPath(root, coverageDirName);
    if (!dir.exists)
        return null;

    const match = indexListings(dir).bestMatch(sourcePath.absolutePath);
    if (match is null)
        return null;

    // An artifact older than the file is *not* refused here any more. Its line
    // numbers do point at the wrong rows — but a `.lst` records the source it
    // counted, so `coverage_rebase` can say exactly which lines moved and which
    // were rewritten, and the reader keeps the ninety lines that did not change
    // instead of losing the file over three that did. What is still worth
    // saying is that the run is behind the file, because a rebased overlay
    // describes the last run and not the current one.
    if (!isFresh(match.artifact, sourcePath))
        info(i"coverage for $(sourcePath) predates the file; re-anchoring onto the current text");
    return match.artifact;
}

/// Whether `artifact` was written no earlier than `source` was last changed.
private bool isFresh(string artifact, string source) @safe
{
    try
        return timeLastModified(artifact) >= timeLastModified(source);
    catch (Exception)
        return false;   // a file that vanished under us is not fresh
}

@("coverage_discovery.sharedSuffixComponents")
@safe pure nothrow @nogc
unittest
{
    // The shapes the two paths actually take: absolute-vs-relative, and a
    // package-relative listing from a run inside the package.
    assert(sharedSuffixComponents(
        "libs/math/src/sparkles/math/vector.d",
        "/repo/libs/math/src/sparkles/math/vector.d") == 6);
    assert(sharedSuffixComponents(
        "src/sparkles/math/vector.d",
        "/repo/libs/math/src/sparkles/math/vector.d") == 4);

    // A shared basename alone is one component, which is what makes
    // longest-match necessary rather than nice.
    assert(sharedSuffixComponents("libs/ui/src/sparkles/ui/package.d",
        "libs/base/src/sparkles/base/package.d") == 1);

    assert(sharedSuffixComponents("a/b.d", "a/c.d") == 0);
    assert(sharedSuffixComponents("", "a.d") == 0);
}

@("coverage_discovery.bestMatchPrefersTheLongestPath")
@safe pure nothrow @nogc
unittest
{
    static immutable CoverageEntry[] entries = [
        CoverageEntry("ui.lst", "libs/ui/src/sparkles/ui/package.d"),
        CoverageEntry("base.lst", "libs/base/src/sparkles/base/package.d"),
        CoverageEntry("input.lst", "libs/input/src/sparkles/input/package.d"),
    ];

    // Every entry is a one-component match on `package.d`; only the longest
    // agreement names the right file. First-wins would answer `ui.lst` here.
    const hit = entries.bestMatch("/repo/libs/base/src/sparkles/base/package.d");
    assert(hit !is null);
    assert(hit.artifact == "base.lst");

    assert(entries.bestMatch("/repo/libs/diff/src/sparkles/diff/model.d") is null);
}

@("coverage_discovery.repositoryRootAndIndex")
@system
unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, rmdirRecurse, setTimes, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    // A temp tree of our own rather than `sparkles:test-utils`: hue's unittest
    // configuration is tuned around a source-included test runner, and one
    // helper is not worth another dependency in it.
    const root = buildPath(tempDir, text("hue-cov-discovery-", thisProcessID));
    if (root.exists)
        root.rmdirRecurse;
    scope (exit)
        if (root.exists)
            root.rmdirRecurse;
    mkdirRecurse(buildPath(root, ".git"));
    mkdirRecurse(buildPath(root, "libs", "x", "src"));
    const covDir = buildPath(root, coverageDirName);
    mkdirRecurse(covDir);

    const src = buildPath(root, "libs", "x", "src", "math.d");
    write(src, "int add(int a, int b) { return a + b; }\n");
    write(buildPath(covDir, "libs-x-src-math.lst"),
        "      5|int add(int a, int b) { return a + b; }\n"
        ~ "libs/x/src/math.d is 100% covered\n");
    // A listing with no trailer names nothing and must not enter the index.
    write(buildPath(covDir, "truncated.lst"), "      5|x();\n");

    assert(repositoryRoot(src) == root);
    assert(repositoryRoot(buildPath(root, "libs", "x")) == root);

    const entries = indexListings(covDir);
    assert(entries.length == 1, "only the listing with a trailer is indexed");
    assert(entries[0].source == "libs/x/src/math.d");

    assert(findCoverageArtifact(src).length, "a fresh artifact is found");

    // Touch the source into the future. The artifact now predates the file,
    // which used to mean "attach nothing" — the overlay went dark on the first
    // keystroke. It is still found: what the listing recorded is evidence the
    // rebase can use, and only the lines that actually changed lose their
    // counters (`coverage_rebase`).
    import std.datetime : Clock, seconds;

    const later = Clock.currTime + 60.seconds;
    src.setTimes(later, later);
    assert(findCoverageArtifact(src).length,
        "an out-of-date artifact is rebased, not refused");
}
