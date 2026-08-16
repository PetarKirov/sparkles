/++
Verify that every SHA-pinned GitHub blob citation in the docs names a path that
actually exists at that commit.

$(LREF checkVcsUrls)'s guarantee stops at the $(I ref): it proves a URL carries a
40-character commit SHA rather than a moving branch or tag. It cannot tell
whether the $(I path) after that SHA resolves — a citation pinned to a real
commit but naming a file that lives one directory over is a 404 that only the
link checker sees, i.e. only in CI, and only when the host is not rate-limiting.

Every surveyed upstream is already cloned locally at the revision it was read at
(the research catalogs' revision ledgers record which), so the question is
answerable offline: `git cat-file -e <sha>:<path>` in the matching clone, for
thousands of citations, with no network and no API budget.

$(B This check is inherently local.) It can only speak for repositories the
machine actually has, so a citation whose repository is not cloned is reported
as $(I unchecked) — never as a failure. That is why it is not wired into CI or
into a pre-commit hook: on a machine without the clones it would have nothing to
say. Run it before publishing a catalog, alongside a real link check.

Split out from `app.d` so the pure parser and matchers can be unit-tested (the
main source file is excluded from the auto-generated test runner).
+/
module blob_paths;

import std.algorithm : startsWith;
import std.array : array;
import std.regex : ctRegex, matchAll;
import std.string : indexOf, lastIndexOf;

/// One SHA-pinned blob citation found in a documentation file.
struct BlobRef
{
    string org;    /// repository owner (`adobe`)
    string repo;   /// repository name (`react-spectrum`)
    string sha;    /// the 40-character commit the citation is pinned to
    string path;   /// repository-relative path, fragment and query stripped
    string url;    /// the URL exactly as it appears in the source
    string file;   /// the documentation file it was found in
    size_t line;   /// 1-based line number within `file`

    /// The `<sha>:<path>` spelling `git cat-file` takes.
    ///
    /// `scope` so callers may take the whole record as `in` (which
    /// `-preview=in` makes `scope const`); both accessors return freshly
    /// concatenated strings, so nothing borrowed escapes.
    @safe pure nothrow
    string revSpec() const scope => sha ~ ":" ~ path;

    /// `org/repo`, the preferred clone-index key.
    @safe pure nothrow
    string slug() const scope => org ~ "/" ~ repo;
}

/// The outcome of checking one citation.
enum BlobStatus
{
    ok,           /// the path exists at that commit
    missingPath,  /// the commit is present but the path is not — a real defect
    noClone,      /// no local clone for that repository; nothing was verified
    noRevision,   /// the clone exists but does not contain that commit
}

/// One checked citation and its verdict.
struct BlobResult
{
    BlobRef ref_;      /// the citation
    BlobStatus status; /// what was found
    string cloneDir;   /// the clone consulted, when there was one
}

/// Aggregate outcome of a run.
struct BlobPathReport
{
    BlobResult[] failures;  /// citations whose path does not resolve
    BlobResult[] unchecked; /// citations with no clone, or no such revision
    size_t okCount;         /// citations verified present
    size_t uniqueCount;     /// distinct (repo, sha, path) triples examined

    /// True when nothing is known to be broken. Unchecked citations do not
    /// fail the run — see the module documentation.
    @safe pure nothrow @nogc
    bool ok() const => failures.length == 0;
}

/++
Decodes the `%XX` escapes GitHub puts in blob paths.

Scoped names produce them routinely — `packages/%40headlessui-react/...` is how
a `@`-prefixed npm scope appears in a URL — and the escaped form does not match
anything on disk.
+/
@safe pure nothrow
string urlDecode(string s)
{
    string decoded;
    for (size_t i = 0; i < s.length; i++)
    {
        if (s[i] == '%' && i + 2 < s.length)
        {
            const hi = hexDigit(s[i + 1]), lo = hexDigit(s[i + 2]);
            if (hi >= 0 && lo >= 0)
            {
                decoded ~= cast(char)(hi * 16 + lo);
                i += 2;
                continue;
            }
        }
        decoded ~= s[i];
    }
    return decoded;
}

/// The value of one hexadecimal digit, or `-1` when `c` is not one.
@safe pure nothrow @nogc
int hexDigit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/++
Reduces a URL tail to the repository-relative path.

Strips the `#L12-L34` line fragment and any `?plain=1` query, then trims the
punctuation a URL collects from the prose around it — a markdown link's closing
paren, a sentence-ending period, a backtick from an inline code span.
+/
@safe pure nothrow
string trimBlobPath(string p)
{
    const hash = p.indexOf('#');
    if (hash >= 0)
        p = p[0 .. hash];

    const query = p.indexOf('?');
    if (query >= 0)
        p = p[0 .. query];

    static immutable trailing = [')', ',', '.', ';', ':', '`', '"', '\'', ']', '>'];
    trim: while (p.length)
    {
        foreach (c; trailing)
            if (p[$ - 1] == c)
            {
                p = p[0 .. $ - 1];
                continue trim;
            }
        break;
    }
    return p;
}

/++
Extracts every SHA-pinned blob citation from `content`.

Both spellings the docs use are recognised: `github.com/<org>/<repo>/blob/<sha>/<path>`
and the `raw.githubusercontent.com/<org>/<repo>/<sha>/<path>` form the link
checker remaps to. Only 40-character hexadecimal refs match, so a branch or tag
URL is left to $(D --check-vcs-urls), which is the check that exists to reject it.
+/
@safe
BlobRef[] parseBlobRefs(string content, string file = "")
{
    static blobRe = ctRegex!(
        `https?://(?:(?:www\.)?github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/blob/([0-9a-fA-F]{40})/`
        ~ `|raw\.githubusercontent\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/([0-9a-fA-F]{40})/)`
        ~ `([^\s"'<>()\[\]]+)`);

    BlobRef[] refs;
    size_t lineNum = 1;
    foreach (line; content.splitLinesKeepingCount)
    {
        foreach (m; line.matchAll(blobRe))
        {
            const blobForm = m.captures[1].length > 0;
            const org = blobForm ? m.captures[1] : m.captures[4];
            const repo = blobForm ? m.captures[2] : m.captures[5];
            const sha = blobForm ? m.captures[3] : m.captures[6];
            // Trim BEFORE decoding. A `#` in a filename travels as `%23`, so
            // decoding first would manufacture a fragment separator and lop
            // off the rest of a legitimate path — `Getting-Started-C%23-Syntax-
            // Analysis.md` becomes `Getting-Started-C`, a false positive.
            const path = urlDecode(trimBlobPath(m.captures[7].idup));
            if (path.length == 0)
                continue;
            refs ~= BlobRef(org.idup, repo.idup, sha.idup, path, m.hit.idup, file, lineNum);
        }
        lineNum++;
    }
    return refs;
}

/// Splits into lines without allocating a joined copy (a thin `lineSplitter`
/// alias kept local so `parseBlobRefs` reads as one pipeline).
private auto splitLinesKeepingCount(string s) @safe pure nothrow
{
    import std.string : lineSplitter;
    return s.lineSplitter;
}

/++
Finds the clone directory for a citation.

`index` maps a lookup key to a clone path. `org/repo` wins when present, so two
forks of one project stay distinguishable; a bare `repo` key is the fallback,
because the repository's `$REPOS` convention buckets by language or org rather
than by owner (`typescript/floating-ui`, not `floating-ui/floating-ui`).
Returns `null` when neither key is known.
+/
@safe pure nothrow
string resolveClone(in string[string] index, in BlobRef r)
{
    if (auto bySlug = r.slug in index)
        return *bySlug;
    if (auto byName = r.repo in index)
        return *byName;
    return null;
}

@("blob_paths.urlDecode")
@safe pure unittest
{
    assert(urlDecode("packages/%40headlessui-react/src") == "packages/@headlessui-react/src");
    assert(urlDecode("plain/path.d") == "plain/path.d");
    // A stray percent that is not an escape must survive untouched.
    assert(urlDecode("100%") == "100%");
    assert(urlDecode("a%2Fb") == "a/b");
}

@("blob_paths.trimBlobPath")
@safe pure unittest
{
    assert(trimBlobPath("src/a.ts#L62") == "src/a.ts");
    assert(trimBlobPath("src/a.ts#L62-L70") == "src/a.ts");
    assert(trimBlobPath("src/a.ts?plain=1") == "src/a.ts");
    assert(trimBlobPath("src/a.ts).") == "src/a.ts");
    assert(trimBlobPath("src/a.ts`") == "src/a.ts");
    assert(trimBlobPath("src/a.ts") == "src/a.ts");
}

@("blob_paths.parseBlobRefs.blobForm")
@safe unittest
{
    const md = "See [it](https://github.com/adobe/react-spectrum/blob/"
        ~ "7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/useSafeArea.ts#L62).";
    auto refs = parseBlobRefs(md, "doc.md");
    assert(refs.length == 1);
    assert(refs[0].org == "adobe");
    assert(refs[0].repo == "react-spectrum");
    assert(refs[0].sha == "7c0765468a1d161ab9ac88ca9f1b54d3603a275c");
    assert(refs[0].path == "packages/react-aria/src/tooltip/useSafeArea.ts");
    assert(refs[0].file == "doc.md");
    assert(refs[0].line == 1);
    assert(refs[0].revSpec ==
        "7c0765468a1d161ab9ac88ca9f1b54d3603a275c:packages/react-aria/src/tooltip/useSafeArea.ts");
}

@("blob_paths.parseBlobRefs.rawForm")
@safe unittest
{
    const md = "https://raw.githubusercontent.com/tmux/tmux/"
        ~ "851c5a933d4838c32ad06c248b2ba975d106149c/popup.c";
    auto refs = parseBlobRefs(md);
    assert(refs.length == 1);
    assert(refs[0].repo == "tmux");
    assert(refs[0].path == "popup.c");
}

@("blob_paths.parseBlobRefs.percentEncodedHashIsNotAFragment")
@safe unittest
{
    // Regression: `%23` is a `#` *in the filename*, not the start of a line
    // fragment. Decoding before trimming truncated the path and reported a
    // valid citation as broken (docs/research/parsing/roslyn.md).
    const md = "https://github.com/dotnet/roslyn/blob/"
        ~ "18bf2c8709264bac6615856e507eb44ba2a026e2/"
        ~ "docs/wiki/Getting-Started-C%23-Syntax-Analysis.md";
    auto refs = parseBlobRefs(md);
    assert(refs.length == 1);
    assert(refs[0].path == "docs/wiki/Getting-Started-C#-Syntax-Analysis.md");
}

@("blob_paths.parseBlobRefs.fragmentStillStrippedWhenReal")
@safe unittest
{
    // …while an actual `#L62` fragment must still go.
    const md = "https://github.com/o/r/blob/"
        ~ "851c5a933d4838c32ad06c248b2ba975d106149c/a%23b.ts#L62";
    auto refs = parseBlobRefs(md);
    assert(refs.length == 1);
    assert(refs[0].path == "a#b.ts");
}

@("blob_paths.parseBlobRefs.ignoresUnpinnedAndDirectoryLinks")
@safe unittest
{
    // A branch ref is --check-vcs-urls' job, not this one; a repo root and a
    // /tree/ link name no file, so there is nothing to resolve.
    const md = "https://github.com/o/r/blob/main/a.d\n"
        ~ "https://github.com/o/r\n"
        ~ "https://github.com/o/r/tree/851c5a933d4838c32ad06c248b2ba975d106149c\n";
    assert(parseBlobRefs(md).length == 0);
}

@("blob_paths.parseBlobRefs.linesAndMultiplePerLine")
@safe unittest
{
    enum sha = "851c5a933d4838c32ad06c248b2ba975d106149c";
    const md = "intro\n"
        ~ "a https://github.com/o/r/blob/" ~ sha ~ "/x.c and "
        ~ "https://github.com/o/r/blob/" ~ sha ~ "/y.c\n";
    auto refs = parseBlobRefs(md, "f.md");
    assert(refs.length == 2);
    assert(refs[0].path == "x.c" && refs[1].path == "y.c");
    assert(refs[0].line == 2 && refs[1].line == 2);
}

@("blob_paths.resolveClone.prefersOrgQualifiedKey")
@safe unittest
{
    string[string] index = [
        "floating-ui": "/repos/typescript/floating-ui",
        "radix-ui/primitives": "/repos/typescript/radix-ui/primitives",
    ];
    auto bare = BlobRef("floating-ui", "floating-ui", "", "a.ts");
    auto slugged = BlobRef("radix-ui", "primitives", "", "a.ts");
    auto unknown = BlobRef("who", "knows", "", "a.ts");

    assert(resolveClone(index, bare) == "/repos/typescript/floating-ui");
    assert(resolveClone(index, slugged) == "/repos/typescript/radix-ui/primitives");
    assert(resolveClone(index, unknown) is null);
}

@("blob_paths.BlobPathReport.uncheckedDoesNotFail")
@safe unittest
{
    BlobPathReport clean;
    clean.unchecked = [BlobResult(BlobRef.init, BlobStatus.noClone)];
    assert(clean.ok, "a citation nobody could check is not a citation known to be broken");

    BlobPathReport broken;
    broken.failures = [BlobResult(BlobRef.init, BlobStatus.missingPath)];
    assert(!broken.ok);
}
