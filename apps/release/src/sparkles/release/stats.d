/++
Commit and release-statistics data types, plus the pure tallying that drives
both the stats display and the bump suggestion.

`git.d` builds the $(LREF Commit) list and the diffstat/author figures; this
module derives the conventional-commit counts ($(LREF tallyCommits),
$(LREF typeCounts)) that `bump.d` and the UI consume.
+/
module sparkles.release.stats;

import sparkles.release.conventional : CommitType, ConventionalCommit;

@safe:

/// One commit in the release range, with its parsed conventional form.
struct Commit
{
    string sha;
    string author;
    string email;
    string subject;
    string body_;
    ConventionalCommit conv;
}

/// An author and how many commits they contributed to the range.
struct AuthorCount
{
    string name;
    size_t commits;
}

/// One file's `git diff --numstat` line (a binary file reports no line counts).
struct FileStat
{
    size_t insertions;
    size_t deletions;
    string path;
    bool binary;
}

/// One row of the per-area change breakdown: a directory label, its tree depth
/// (0 = top-level area, 1 = sub-area), and its summed line counts.
struct AreaStat
{
    string label;
    size_t depth;
    size_t insertions;
    size_t deletions;
}

/// The counts the bump policy needs: features, fixes, breaking changes, and the
/// total commit count.
struct CommitTally
{
    size_t feat;
    size_t fix;
    size_t breaking;
    size_t total;
}

/// Everything the stats screen renders for a release range.
struct ReleaseStats
{
    size_t commitCount;
    size_t filesChanged;
    size_t insertions;
    size_t deletions;
    AuthorCount[] authors;
    size_t[CommitType.max + 1] typeCounts;
    size_t breakingCount;
    CommitTally tally;
    AreaStat[] areas;
}

/// Counts features, fixes, breaking changes and the total across `commits`.
CommitTally tallyCommits(in Commit[] commits) @safe pure nothrow @nogc
{
    CommitTally t;
    t.total = commits.length;
    foreach (ref c; commits)
    {
        if (c.conv.breaking)
            t.breaking++;
        if (c.conv.type == CommitType.feat)
            t.feat++;
        else if (c.conv.type == CommitType.fix)
            t.fix++;
    }
    return t;
}

/// Per-`CommitType` commit counts, indexed by the enum value.
size_t[CommitType.max + 1] typeCounts(in Commit[] commits) @safe pure nothrow @nogc
{
    size_t[CommitType.max + 1] counts;
    foreach (ref c; commits)
        counts[c.conv.type]++;
    return counts;
}

/// Top-level areas shown first (in this order); any other area follows
/// alphabetically, with repo-root files (`(root)`) last.
private enum string[] preferredTopOrder = ["apps", "libs", "docs", "nix"];

/// Aggregates per-file `FileStat`s into a directory tree of insertions/deletions.
/// Top-level directories named in `expandable` are broken down one level further
/// (e.g. `apps/` → `apps/ci/`, `apps/release/`); everything else is a single row.
/// Rows are returned in display order (parents immediately followed by children).
AreaStat[] areaBreakdown(in FileStat[] files, const(string)[] expandable) @safe pure
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import std.string : split;

    size_t[string] topIns, topDel;
    string[] topsSeen;
    size_t[string] subIns, subDel;     // keyed "top/child"
    string[][string] childrenOf;       // top -> child names, insertion order

    foreach (f; files)
    {
        const comps = f.path.split("/");
        const top = comps.length <= 1 ? "(root)" : comps[0];
        if (top !in topIns)
        {
            topIns[top] = 0;
            topDel[top] = 0;
            topsSeen ~= top;
        }
        topIns[top] += f.insertions;
        topDel[top] += f.deletions;

        // Only break out a sub-area when the second component is itself a
        // directory (depth ≥ 3); a file directly under the top (e.g.
        // `docs/index.md`) just counts toward the top total.
        if (comps.length >= 3 && expandable.canFind(top))
        {
            const child = comps[1];
            const key = top ~ "/" ~ child;
            if (key !in subIns)
            {
                subIns[key] = 0;
                subDel[key] = 0;
                childrenOf[top] ~= child;
            }
            subIns[key] += f.insertions;
            subDel[key] += f.deletions;
        }
    }

    AreaStat[] rows;
    foreach (top; orderTops(topsSeen))
    {
        const label = top == "(root)" ? top : top ~ "/";
        rows ~= AreaStat(label: label, depth: 0, insertions: topIns[top], deletions: topDel[top]);
        if (auto kids = top in childrenOf)
            foreach (child; (*kids).dup.sort)
            {
                const key = top ~ "/" ~ child;
                rows ~= AreaStat(label: child ~ "/", depth: 1, insertions: subIns[key], deletions: subDel[key]);
            }
    }
    return rows;
}

/// Orders top-level areas: `preferredTopOrder` first, then the rest
/// alphabetically, with `(root)` last.
private string[] orderTops(string[] seen) @safe pure
{
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;

    string[] ordered;
    foreach (p; preferredTopOrder)
        if (seen.canFind(p))
            ordered ~= p;

    string[] rest;
    foreach (s; seen)
        if (s != "(root)" && !preferredTopOrder.canFind(s))
            rest ~= s;
    ordered ~= rest.sort.release;

    if (seen.canFind("(root)"))
        ordered ~= "(root)";
    return ordered;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    private Commit mk(string subject, string body_ = "") @safe pure nothrow
    {
        import sparkles.release.conventional : parseConventional;

        Commit c;
        c.subject = subject;
        c.body_ = body_;
        c.conv = parseConventional(subject, body_);
        return c;
    }
}

@("stats.tallyCommits.counts")
@safe pure nothrow
unittest
{
    auto commits = [
        mk("feat(base): a"),
        mk("feat(core-cli): b"),
        mk("fix(versions): c"),
        mk("docs: d"),
        mk("feat(base)!: e"),                 // feat + breaking
        mk("refactor: f", "BREAKING CHANGE: g"), // breaking only
    ];
    const t = tallyCommits(commits);
    assert(t.total == 6);
    assert(t.feat == 3);
    assert(t.fix == 1);
    assert(t.breaking == 2);
}

@("stats.typeCounts.breakdown")
@safe pure nothrow
unittest
{
    auto commits = [mk("feat: a"), mk("feat: b"), mk("chore: c"), mk("weird thing")];
    const counts = typeCounts(commits);
    assert(counts[CommitType.feat] == 2);
    assert(counts[CommitType.chore] == 1);
    assert(counts[CommitType.other] == 1);
    assert(counts[CommitType.fix] == 0);
}

@("stats.areaBreakdown.treeAndOrder")
@safe pure
unittest
{
    auto files = [
        FileStat(10, 1, "apps/release/src/app.d"),
        FileStat(5, 0, "apps/ci/src/app.d"),
        FileStat(3, 2, "libs/base/src/x.d"),
        FileStat(20, 4, "docs/guidelines/release.md"),
        FileStat(7, 1, "docs/index.md"),         // file directly under docs/
        FileStat(1, 1, "nix/packages/default.nix"),
        FileStat(2, 0, "dub.sdl"),               // repo-root file
    ];
    const rows = areaBreakdown(files, ["apps", "libs", "docs"]);

    // Parent rows precede children; preferred order apps, libs, docs, nix, (root).
    assert(rows[0].label == "apps/" && rows[0].depth == 0);
    assert(rows[0].insertions == 15 && rows[0].deletions == 1);   // ci + release
    assert(rows[1].label == "ci/" && rows[1].depth == 1 && rows[1].insertions == 5);
    assert(rows[2].label == "release/" && rows[2].depth == 1 && rows[2].insertions == 10);
    assert(rows[3].label == "libs/" && rows[3].depth == 0);
    assert(rows[4].label == "base/" && rows[4].depth == 1);

    // docs/ total includes the directly-nested index.md, but only the real
    // sub-directory (guidelines) gets a child row.
    assert(rows[5].label == "docs/" && rows[5].insertions == 27);
    assert(rows[6].label == "guidelines/" && rows[6].depth == 1);
    import std.algorithm.searching : canFind;
    assert(!rows.canFind!(r => r.label == "index.md/"));

    // nix is not expandable → single row, no children.
    const nix = rows[$ - 2];
    assert(nix.label == "nix/" && nix.depth == 0 && nix.insertions == 1);
    // repo-root files grouped last under "(root)".
    assert(rows[$ - 1].label == "(root)" && rows[$ - 1].insertions == 2);
}
