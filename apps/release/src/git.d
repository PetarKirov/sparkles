/++
Git porcelain wrappers.

Every `git` invocation the tool makes lives here, each returning parsed D data
(or a $(REF Result, result) error). Commands use stable plumbing/porcelain flags
and `\x1f`/`\x1e` field/record separators so multi-line commit bodies parse
unambiguously. All run through $(REF runCaptured, sparkles,core_cli,process_utils),
so a failing git command yields an error rather than throwing.
+/
module git;

import std.typecons : Nullable, nullable;

import sparkles.core_cli.process_utils : runCaptured;
import sparkles.versions.schemes.semver : SemVer;

import conventional : parseConventional;
import result : Result, success, failure;
import stats : Commit, AuthorCount, FileStat;

@safe:

/// The well-known empty-tree object — used as the lower bound of a "whole
/// history" diff when there is no previous tag.
private enum emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// A git tag that parsed as SemVer.
struct TaggedVersion
{
    string tag;        /// the literal tag (e.g. `v0.4.0`)
    SemVer version_;   /// its parsed form
}

/// Aggregate diff totals for a range.
struct DiffStat
{
    size_t filesChanged;
    size_t insertions;
    size_t deletions;
}

// ---------------------------------------------------------------------------
// Command runner
// ---------------------------------------------------------------------------

/// Runs `git args` and returns its stdout, or a failure carrying git's stderr.
private Result!string git(const(string)[] args, string workDir = null)
{
    import std.array : join;
    import std.string : strip;

    const(string)[] argv = "git" ~ args;
    auto r = runCaptured(argv, null, workDir);
    if (r.status != 0)
        return failure!string(
            "`git " ~ args.join(" ") ~ "` failed: " ~ r.stderr.strip.idup);
    return success(r.stdout);
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// All tags that parse as SemVer (via `parseLoose`, so the `v` prefix is fine),
/// each paired with its parsed version. Non-SemVer tags are dropped.
Result!(TaggedVersion[]) listTags()
{
    import std.string : lineSplitter, strip;

    auto res = git(["tag", "--list"]);
    if (res.hasError)
        return failure!(TaggedVersion[])(res.error);

    TaggedVersion[] tags;
    foreach (line; res.value.lineSplitter)
    {
        const tag = line.strip.idup;
        if (tag.length == 0)
            continue;
        auto parsed = SemVer.parseLoose(tag);
        if (parsed.hasValue)
            tags ~= TaggedVersion(tag, parsed.value);
    }
    return success(tags);
}

/// The highest SemVer tag, or null when there are none. Pure so it is testable.
Nullable!TaggedVersion latestTag(TaggedVersion[] tags) @safe pure nothrow
{
    if (tags.length == 0)
        return Nullable!TaggedVersion.init;

    auto best = tags[0];
    foreach (t; tags[1 .. $])
        if (t.version_ > best.version_)
            best = t;
    return nullable(best);
}

/// True when a tag with this exact name already exists.
Result!bool tagExists(string tag)
{
    import std.string : strip;

    auto res = git(["tag", "--list", tag]);
    if (res.hasError)
        return failure!bool(res.error);
    return success(res.value.strip.length != 0);
}

/// Commits in `from..to` (or the whole history of `to` when `from` is empty),
/// newest first, merges excluded, each parsed as a conventional commit.
Result!(Commit[]) logRange(string from, string to)
{
    import std.array : split;
    import std.string : strip;

    const range = from.length ? from ~ ".." ~ to : to;
    auto res = git([
        "log", range, "--no-merges",
        "--pretty=format:%H%x1f%an%x1f%ae%x1f%s%x1f%b%x1e",
    ]);
    if (res.hasError)
        return failure!(Commit[])(res.error);

    Commit[] commits;
    foreach (rec; res.value.split("\x1e"))
    {
        const record = rec.strip;        // drop git's inter-record newline
        if (record.length == 0)
            continue;
        auto f = record.split("\x1f");
        if (f.length < 5)
            continue;
        Commit c;
        c.sha = f[0];
        c.author = f[1];
        c.email = f[2];
        c.subject = f[3];
        c.body_ = f[4];
        c.conv = parseConventional(c.subject, c.body_);
        commits ~= c;
    }
    return success(commits);
}

/// Diff totals for the range (`emptyTree..to` when `from` is empty).
Result!DiffStat diffStat(string from, string to)
{
    const lo = from.length ? from : emptyTree;
    auto res = git(["diff", "--shortstat", lo ~ ".." ~ to]);
    if (res.hasError)
        return failure!DiffStat(res.error);
    return success(parseShortStat(res.value));
}

/// Per-file insertion/deletion counts for the range (`git diff --numstat`),
/// used for the per-area breakdown.
Result!(FileStat[]) numstat(string from, string to)
{
    import std.string : lineSplitter;

    const lo = from.length ? from : emptyTree;
    // --no-renames keeps paths clean (a rename becomes delete + add) instead of
    // emitting `{old => new}` notation that would pollute the area grouping.
    auto res = git(["diff", "--numstat", "--no-renames", lo ~ ".." ~ to]);
    if (res.hasError)
        return failure!(FileStat[])(res.error);

    FileStat[] files;
    foreach (line; res.value.lineSplitter)
        if (auto parsed = parseNumstatLine(line))
            files ~= parsed.get;
    return success(files);
}

/// Per-author commit counts for the range, busiest first.
Result!(AuthorCount[]) authorCounts(string from, string to)
{
    import std.string : lineSplitter, strip;

    const range = from.length ? from ~ ".." ~ to : to;
    auto res = git(["shortlog", "-sn", "--no-merges", range]);
    if (res.hasError)
        return failure!(AuthorCount[])(res.error);

    AuthorCount[] authors;
    foreach (line; res.value.lineSplitter)
        if (auto parsed = parseShortlogLine(line))
            authors ~= parsed.get;
    return success(authors);
}

/// The human-readable `git log --stat` for the range (used to seed $EDITOR and
/// the agent prompt).
Result!string logStatRange(string from, string to)
{
    const range = from.length ? from ~ ".." ~ to : to;
    return git(["log", "--stat", range]);
}

/// True when the working tree has no uncommitted changes.
Result!bool isWorkingTreeClean()
{
    auto res = git(["status", "--porcelain"]);
    if (res.hasError)
        return failure!bool(res.error);
    return success(res.value.length == 0);
}

/// The current branch name, or `HEAD` when detached.
Result!string currentBranch()
{
    import std.string : strip;

    auto res = git(["rev-parse", "--abbrev-ref", "HEAD"]);
    if (res.hasError)
        return res;
    return success(res.value.strip.idup);
}

/// The absolute repository root.
Result!string repoRoot()
{
    import std.string : strip;

    auto res = git(["rev-parse", "--show-toplevel"]);
    if (res.hasError)
        return res;
    return success(res.value.strip.idup);
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

/// Creates an annotated tag whose body is read from `messageFile`.
Result!void createAnnotatedTag(string tag, string messageFile)
{
    auto res = git(["tag", "-a", tag, "-F", messageFile]);
    if (res.hasError)
        return failure!void(res.error);
    return success();
}

/// Pushes `tag` to `remote` (default `origin`).
Result!void pushTag(string tag, string remote = "origin")
{
    auto res = git(["push", remote, tag]);
    if (res.hasError)
        return failure!void(res.error);
    return success();
}

// ---------------------------------------------------------------------------
// Parsers (pure, testable)
// ---------------------------------------------------------------------------

/// Parses a `git diff --shortstat` line:
/// `N files changed, M insertions(+), K deletions(-)` (any clause may be absent).
DiffStat parseShortStat(scope const(char)[] s) @safe pure nothrow @nogc
{
    DiffStat d;
    size_t start = 0;
    while (start <= s.length)
    {
        size_t end = start;
        while (end < s.length && s[end] != ',')
            end++;
        const clause = s[start .. end];
        const n = leadingUint(clause);
        if (clause.containsWord("file"))
            d.filesChanged = n;
        else if (clause.containsWord("insertion"))
            d.insertions = n;
        else if (clause.containsWord("deletion"))
            d.deletions = n;
        if (end == s.length)
            break;
        start = end + 1;
    }
    return d;
}

/// Parses a `git diff --numstat` line: `<ins>\t<del>\t<path>`. A binary file
/// reports `-\t-\t<path>` (counted as zero, `binary = true`). Null on a blank
/// or malformed line.
Nullable!FileStat parseNumstatLine(scope const(char)[] line) @safe pure nothrow
{
    import std.string : strip;

    const t = line.strip;
    if (t.length == 0)
        return Nullable!FileStat.init;

    // Field 1: insertions (or '-' for binary).
    size_t i = 0;
    const insTok = nextField(t, i);
    const delTok = nextField(t, i);
    if (i > t.length || delTok.length == 0)
        return Nullable!FileStat.init;
    const path = t[i .. $];                 // remainder is the path
    if (path.length == 0)
        return Nullable!FileStat.init;

    const binary = insTok == "-" || delTok == "-";
    FileStat f;
    f.binary = binary;
    f.insertions = binary ? 0 : allDigits(insTok);
    f.deletions = binary ? 0 : allDigits(delTok);
    f.path = path.idup;
    return nullable(f);
}

/// Reads the next tab-delimited field starting at `i`, advancing `i` past the tab.
private const(char)[] nextField(scope return const(char)[] s, ref size_t i)
    @safe pure nothrow @nogc
{
    const start = i;
    while (i < s.length && s[i] != '\t')
        i++;
    const field = s[start .. i];
    if (i < s.length)
        i++;                                // skip the tab
    return field;
}

private size_t allDigits(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t n = 0;
    foreach (c; s)
        if (c >= '0' && c <= '9')
            n = n * 10 + (c - '0');
    return n;
}

/// Parses a `git shortlog -sn` line (`\t`-separated `count` and `name`).
Nullable!AuthorCount parseShortlogLine(scope const(char)[] line)
    @safe pure nothrow
{
    import std.string : strip;

    const t = line.strip;
    if (t.length == 0)
        return Nullable!AuthorCount.init;

    size_t i = 0;
    size_t count = 0;
    while (i < t.length && t[i] >= '0' && t[i] <= '9')
    {
        count = count * 10 + (t[i] - '0');
        i++;
    }
    if (i == 0)
        return Nullable!AuthorCount.init;

    // Skip the separating whitespace (tab/spaces) before the name.
    while (i < t.length && (t[i] == ' ' || t[i] == '\t'))
        i++;
    return nullable(AuthorCount(t[i .. $].idup, count));
}

// ----- shortstat helpers -----

private size_t leadingUint(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t i = 0, n = 0;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t'))
        i++;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
    {
        n = n * 10 + (s[i] - '0');
        i++;
    }
    return n;
}

private bool containsWord(scope const(char)[] hay, scope const(char)[] needle)
    @safe pure nothrow @nogc
{
    if (needle.length == 0 || hay.length < needle.length)
        return false;
    foreach (start; 0 .. hay.length - needle.length + 1)
        if (hay[start .. start + needle.length] == needle)
            return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("git.parseShortStat.fullLine")
@safe pure nothrow
unittest
{
    const d = parseShortStat(" 12 files changed, 340 insertions(+), 21 deletions(-)");
    assert(d.filesChanged == 12);
    assert(d.insertions == 340);
    assert(d.deletions == 21);
}

@("git.parseShortStat.partial")
@safe pure nothrow
unittest
{
    const d = parseShortStat(" 1 file changed, 5 insertions(+)");
    assert(d.filesChanged == 1);
    assert(d.insertions == 5);
    assert(d.deletions == 0);
}

@("git.parseNumstatLine")
@safe pure nothrow
unittest
{
    const a = parseNumstatLine("10\t3\tapps/release/src/app.d");
    assert(!a.isNull);
    assert(a.get.insertions == 10 && a.get.deletions == 3);
    assert(a.get.path == "apps/release/src/app.d" && !a.get.binary);

    const b = parseNumstatLine("-\t-\tassets/logo.png");
    assert(!b.isNull);
    assert(b.get.binary && b.get.insertions == 0 && b.get.deletions == 0);
    assert(b.get.path == "assets/logo.png");

    assert(parseNumstatLine("").isNull);
}

@("git.parseShortlogLine")
@safe pure nothrow
unittest
{
    const a = parseShortlogLine("   170\tPetar Kirov");
    assert(!a.isNull);
    assert(a.get.commits == 170);
    assert(a.get.name == "Petar Kirov");

    assert(parseShortlogLine("   ").isNull);
}

@("git.latestTag.picksHighest")
@safe pure nothrow
unittest
{
    auto tags = [
        TaggedVersion("v0.1.0", SemVer(major: 0, minor: 1, patch: 0)),
        TaggedVersion("v0.10.0", SemVer(major: 0, minor: 10, patch: 0)),
        TaggedVersion("v0.2.0", SemVer(major: 0, minor: 2, patch: 0)),
    ];
    const best = latestTag(tags);
    assert(!best.isNull);
    assert(best.get.tag == "v0.10.0");          // not lexical "v0.2.0"

    assert(latestTag([]).isNull);
}
