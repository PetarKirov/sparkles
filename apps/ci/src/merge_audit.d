/++
`ci --ci-stats --merges` — what actually lands on `main`, and what it would
cost to verify it.

The repository merges by rebase, so every commit on `main` carries a SHA that
no CI run has ever seen. The checks a visitor sees next to `main`'s tip are
therefore not the checks the pull request passed; today they are a single
`lint` job, and its red cross is what the repository looks like.

Mirroring the pull request's checks onto the landed commit is honest exactly
when the landed **tree** equals the tree the pull request tested — a rebase
that changed nothing but parentage. That is not an assumption to make; it is a
fact to measure, and this module measures it:

$(LIST
    $(ITEM how many merged pull requests landed a tree CI had already built,)
    $(ITEM how many did not, and so would need a real run on `main`,)
    $(ITEM how many commits each carried onto the branch, and)
    $(ITEM what share of merged pull requests were green at the head.))

One GraphQL request per page answers all four: the head commit's tree and
status rollup, the merge commit's tree, and the commit count come back
together, where the REST equivalent is two commit fetches per pull request.

Fetching goes through `ci_stats`' `FetchJson` seam, so the pure classification
and summary pipelines below are testable with no network.
+/
module merge_audit;

import std.algorithm.iteration : filter, map, sum;
import std.algorithm.searching : count;
import std.array : array;
import std.conv : text, to;
import std.datetime : SysTime;
import std.range.primitives : empty;
import std.typecons : Nullable;

import core.time : days, Duration;

import sparkles.base.styled_template : styledWriteln;
import sparkles.ui.components.table : drawTable, TableProps;

import sparkles.wired : fromJSON, WireName, WireOptional;

import ci_stats : failure, Result, success;

// ---------------------------------------------------------------------------
// GraphQL response models (wired-decodable)
// ---------------------------------------------------------------------------

private struct GqlTree
{
    string oid;
}

private struct GqlRollup
{
    string state;
}

private struct GqlCommit
{
    string oid;
    GqlTree tree;
    // Absent when no check or status ever reported on the head commit — an old
    // pull request, or one whose workflow never triggered.
    Nullable!GqlRollup statusCheckRollup;
}

private struct GqlCommitNode
{
    GqlCommit commit;
}

private struct GqlCommitConnection
{
    int totalCount;
    GqlCommitNode[] nodes;
}

private struct GqlMergeCommit
{
    string oid;
    GqlTree tree;
}

private struct GqlPullRequest
{
    int number;
    string title;
    string mergedAt;
    GqlCommitConnection commits;
    // Null for a pull request GitHub recorded as merged without attributing a
    // commit (an ancient merge, or one performed outside the API).
    Nullable!GqlMergeCommit mergeCommit;
}

private struct GqlPageInfo
{
    bool hasNextPage;
    Nullable!string endCursor;
}

private struct GqlPullRequestConnection
{
    GqlPageInfo pageInfo;
    GqlPullRequest[] nodes;
}

private struct GqlRepository
{
    GqlPullRequestConnection pullRequests;
}

private struct GqlData
{
    GqlRepository repository;
}

private struct GqlError
{
    string message;
}

private struct GqlResponse
{
    // GraphQL returns exactly one of these two on a 200, so neither is a
    // required field: demanding `errors` aborts the decode on every success.
    @WireOptional() Nullable!GqlData data;
    @WireOptional() GqlError[] errors;
}

// ---------------------------------------------------------------------------
// Domain model
// ---------------------------------------------------------------------------

/// How the commits of one merged pull request arrived on the default branch.
enum Landing
{
    /// The landed tree is byte-identical to the tree CI built on the pull
    /// request. Its checks describe this commit exactly, so they can be
    /// mirrored onto it without claiming anything untested.
    mirrorable,

    /// The base moved under the pull request, so the rebase produced a tree no
    /// run has ever built. Only a real run on `main` can speak for it.
    rebuilt,

    /// No merge commit is recorded, so the two trees cannot be compared.
    unknown,
}

/// One merged pull request, reduced to what the cost question needs.
struct MergedPr
{
    int number;
    string title;
    string mergedAt;
    /// Commits the pull request carried onto the branch.
    int commits;
    /// Tree of the pull request's head commit — what CI built.
    string headTree;
    /// Tree of the commit that landed, or empty when none is recorded.
    string landedTree;
    /// The head commit's combined check rollup: `SUCCESS`, `FAILURE`,
    /// `PENDING`, `ERROR`, `EXPECTED`, or `NONE` when nothing reported.
    string rollup;

    Landing landing() const scope @safe pure nothrow @nogc
    {
        if (landedTree.empty)
            return Landing.unknown;
        return landedTree == headTree ? Landing.mirrorable : Landing.rebuilt;
    }

    bool green() const scope @safe pure nothrow @nogc => rollup == "SUCCESS";
}

/// The answer to "what would this cost?", over one window of merges.
struct MergeAudit
{
    size_t pullRequests;
    size_t commits;
    size_t mirrorable;
    size_t rebuilt;
    size_t unknown;
    size_t green;
    /// Oldest and newest merge in the window; both empty when it is empty.
    string firstMerge;
    string lastMerge;

    double pct(size_t n) const scope @safe pure nothrow @nogc
        => pullRequests == 0 ? 0.0 : 100.0 * n / pullRequests;

    /// Merges per week over the observed window, or 0 when it is shorter than
    /// an hour (too small a base to divide by honestly).
    double mergesPerWeek() const scope @safe
    {
        const span = windowSpan;
        if (span < 1.days / 24)
            return 0.0;
        return pullRequests * (7.0 * 24 * 60 * 60) / span.total!"seconds";
    }

    /// Full runs on `main` a "rebuild what could not be mirrored" policy would
    /// add per week — the number the cost question is really asking for.
    double rebuildsPerWeek() const scope @safe
        => pullRequests == 0 ? 0.0 : mergesPerWeek * rebuilt / pullRequests;

    Duration windowSpan() const scope @safe
    {
        if (firstMerge.empty || lastMerge.empty)
            return Duration.zero;
        try
            return SysTime.fromISOExtString(lastMerge) - SysTime.fromISOExtString(firstMerge);
        catch (Exception)
            return Duration.zero;
    }
}

/// Reduce a window of merged pull requests to the audit. Pure: the network
/// half is the caller's problem.
MergeAudit auditMerges(in MergedPr[] prs) @safe
{
    MergeAudit a;
    a.pullRequests = prs.length;
    a.commits = prs.map!(p => cast(size_t) p.commits).sum;
    a.mirrorable = prs.count!(p => p.landing == Landing.mirrorable);
    a.rebuilt = prs.count!(p => p.landing == Landing.rebuilt);
    a.unknown = prs.count!(p => p.landing == Landing.unknown);
    a.green = prs.count!(p => p.green);

    foreach (p; prs)
    {
        if (p.mergedAt.empty)
            continue;
        if (a.firstMerge.empty || p.mergedAt < a.firstMerge)
            a.firstMerge = p.mergedAt;
        if (a.lastMerge.empty || p.mergedAt > a.lastMerge)
            a.lastMerge = p.mergedAt;
    }
    return a;
}

@("merge_audit.auditMerges.classifiesAndCounts")
@safe unittest
{
    const prs = [
        MergedPr(number: 1, mergedAt: "2026-08-01T00:00:00Z", commits: 3,
            headTree: "aaa", landedTree: "aaa", rollup: "SUCCESS"),
        MergedPr(number: 2, mergedAt: "2026-08-08T00:00:00Z", commits: 2,
            headTree: "bbb", landedTree: "ccc", rollup: "SUCCESS"),
        MergedPr(number: 3, mergedAt: "2026-08-04T00:00:00Z", commits: 1,
            headTree: "ddd", landedTree: "", rollup: "PENDING"),
    ];
    const a = auditMerges(prs);
    assert(a.pullRequests == 3 && a.commits == 6);
    assert(a.mirrorable == 1 && a.rebuilt == 1 && a.unknown == 1);
    assert(a.green == 2);
    assert(a.firstMerge == "2026-08-01T00:00:00Z");
    assert(a.lastMerge == "2026-08-08T00:00:00Z");
    // One rebuild across a one-week window is one rebuild per week.
    assert(a.rebuildsPerWeek > 0.99 && a.rebuildsPerWeek < 1.01);
}

@("merge_audit.auditMerges.emptyWindowDividesByNothing")
@safe unittest
{
    const a = auditMerges(null);
    assert(a.pullRequests == 0 && a.pct(0) == 0.0);
    assert(a.mergesPerWeek == 0.0 && a.rebuildsPerWeek == 0.0);
    assert(a.windowSpan == Duration.zero);
}

@("merge_audit.MergedPr.landing.treeEqualityIsTheTest")
@safe pure nothrow @nogc unittest
{
    assert(MergedPr(headTree: "t", landedTree: "t").landing == Landing.mirrorable);
    assert(MergedPr(headTree: "t", landedTree: "u").landing == Landing.rebuilt);
    assert(MergedPr(headTree: "t").landing == Landing.unknown);
}

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

/// One page of merged pull requests, with both trees, the commit count and the
/// head rollup — everything `MergedPr` needs, in a single round trip.
private enum mergedPrQuery = `
query($owner:String!,$name:String!,$n:Int!,$cursor:String){
    repository(owner:$owner,name:$name){
        pullRequests(states:MERGED, first:$n, orderBy:{field:UPDATED_AT,direction:DESC}, after:$cursor){
            pageInfo{ hasNextPage endCursor }
            nodes{
                number title mergedAt
                commits(last:1){ totalCount nodes{ commit{ oid tree{oid} statusCheckRollup{state} } } }
                mergeCommit{ oid tree{oid} }
            }
        }
    }
}`;

/// Build the GraphQL request body. Split out so the escaping is testable
/// without a network call.
string mergedPrRequestBody(string owner, string name, int pageSize, string cursor) @safe
{
    import std.json : JSONValue;

    JSONValue vars;
    vars["owner"] = owner;
    vars["name"] = name;
    vars["n"] = pageSize;
    vars["cursor"] = cursor.empty ? JSONValue(null) : JSONValue(cursor);

    JSONValue root;
    root["query"] = mergedPrQuery;
    root["variables"] = vars;
    return root.toString;
}

@("merge_audit.mergedPrRequestBody.firstPageSendsNullCursor")
@safe unittest
{
    import std.json : parseJSON;

    auto body_ = parseJSON(mergedPrRequestBody("PetarKirov", "sparkles", 50, ""));
    assert(body_["variables"]["owner"].str == "PetarKirov");
    assert(body_["variables"]["n"].integer == 50);
    assert(body_["variables"]["cursor"].isNull);

    auto next = parseJSON(mergedPrRequestBody("o", "n", 50, "Y3Vyc29yOjE="));
    assert(next["variables"]["cursor"].str == "Y3Vyc29yOjE=");
}

/// A repository coordinate, split from `owner/repo`.
struct RepoRef
{
    string owner;
    string name;
}

/// Split `owner/repo`. Returns a failure rather than throwing so the caller's
/// `Expected` chain stays intact.
Result!RepoRef splitRepo(string repo) @safe
{
    import std.string : indexOf;

    const slash = repo.indexOf('/');
    if (slash <= 0 || slash + 1 >= repo.length)
        return failure!RepoRef("repo must be owner/repo, got '" ~ repo ~ "'");
    return success(RepoRef(repo[0 .. slash], repo[slash + 1 .. $]));
}

@("merge_audit.splitRepo.rejectsMalformed")
@safe unittest
{
    assert(splitRepo("PetarKirov/sparkles").value == RepoRef("PetarKirov", "sparkles"));
    assert(splitRepo("sparkles").hasError);
    assert(splitRepo("/sparkles").hasError);
    assert(splitRepo("PetarKirov/").hasError);
}

/// Translate one GraphQL node into the domain model.
private MergedPr toMergedPr(const GqlPullRequest n) @safe
{
    MergedPr p;
    p.number = n.number;
    p.title = n.title;
    p.mergedAt = n.mergedAt;
    p.commits = n.commits.totalCount;
    if (!n.commits.nodes.empty)
    {
        p.headTree = n.commits.nodes[0].commit.tree.oid;
        p.rollup = n.commits.nodes[0].commit.statusCheckRollup.isNull
            ? "NONE" : n.commits.nodes[0].commit.statusCheckRollup.get.state;
    }
    if (!n.mergeCommit.isNull)
        p.landedTree = n.mergeCommit.get.tree.oid;
    return p;
}

/// Fetch up to `limit` merged pull requests, newest first, paging as needed.
Result!(MergedPr[]) fetchMergedPrs(alias fetchJson)(
    string repo, string token, int limit,
)
{
    import std.algorithm.comparison : min;

    auto parts = splitRepo(repo);
    if (parts.hasError)
        return failure!(MergedPr[])(parts.error);

    string[string] headers;
    if (token.length)
        headers["Authorization"] = "Bearer " ~ token;

    MergedPr[] all;
    string cursor;
    while (all.length < cast(size_t) limit)
    {
        const pageSize = min(100, limit - cast(int) all.length);
        auto page = fetchJson!GqlResponse(
            "https://api.github.com/graphql", "POST",
            mergedPrRequestBody(parts.value.owner, parts.value.name, pageSize, cursor),
            headers,
        );
        if (page.hasError)
            return failure!(MergedPr[])(page.error);

        // GraphQL reports failure in a 200 body, so an unchecked `data` would
        // silently read as "no merges" on an auth or query error.
        if (!page.value.errors.empty)
            return failure!(MergedPr[])("GraphQL error: " ~ page.value.errors[0].message);
        if (page.value.data.isNull)
            return failure!(MergedPr[])("GraphQL response carried neither data nor errors");

        const conn = page.value.data.get.repository.pullRequests;
        foreach (node; conn.nodes)
            all ~= toMergedPr(node);

        if (!conn.pageInfo.hasNextPage || conn.pageInfo.endCursor.isNull || conn.nodes.empty)
            break;
        cursor = conn.pageInfo.endCursor.get;
    }
    return success(all);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// One decimal place, which is all a share of a few hundred merges supports.
private string oneDp(double v) @safe => text(cast(long)(v * 10 + 0.5) / 10.0);

private string pctText(double v) @safe => oneDp(v) ~ "%";

@("merge_audit.oneDp.roundsHalfUp")
@safe unittest
{
    assert(oneDp(0.0) == "0");
    assert(oneDp(73.33) == "73.3");
    assert(oneDp(73.35) == "73.4");
    assert(pctText(100.0) == "100%");
}

private string landingText(Landing l) @safe
{
    final switch (l)
    {
        case Landing.mirrorable: return "mirror";
        case Landing.rebuilt:    return "rebuild";
        case Landing.unknown:    return "unknown";
    }
}

/// Render the audit: the rebuilt pull requests by name (they are the cost), then
/// the totals.
void renderMergeAudit(in MergedPr[] prs, in MergeAudit a)
{
    import std.stdio : writeln;
    import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;

    writeln();
    writeln(drawHeader("Merges landing on the default branch",
        HeaderProps(style: HeaderStyle.banner)));

    string[][] rows = [["Landing", "PRs", "Share", "Commits"]];
    foreach (l; [Landing.mirrorable, Landing.rebuilt, Landing.unknown])
    {
        const bucket = prs.filter!(p => p.landing == l).array;
        if (bucket.empty)
            continue;
        rows ~= [
            landingText(l),
            bucket.length.to!string,
            pctText(a.pct(bucket.length)),
            bucket.map!(p => cast(size_t) p.commits).sum.to!string,
        ];
    }
    rows ~= ["total", a.pullRequests.to!string, "100%", a.commits.to!string];
    writeln(drawTable(rows, TableProps(headerRows: 1, title: "By landing")));

    const rebuilt = prs.filter!(p => p.landing == Landing.rebuilt).array;
    if (!rebuilt.empty)
    {
        string[][] detail = [["PR", "Commits", "Merged", "Rollup", "Title"]];
        foreach (p; rebuilt)
            detail ~= [
                "#" ~ p.number.to!string,
                p.commits.to!string,
                p.mergedAt.length >= 10 ? p.mergedAt[0 .. 10] : p.mergedAt,
                p.rollup,
                p.title,
            ];
        writeln();
        writeln(drawTable(detail, TableProps(headerRows: 1,
            title: "Would need a real run on the default branch")));
    }

    const days_ = a.windowSpan.total!"days";
    const perWeek = oneDp(a.mergesPerWeek);
    const rebuildsWeek = oneDp(a.rebuildsPerWeek);
    const greenPct = pctText(a.pct(a.green));
    writeln();
    styledWriteln(i"Window: $(a.firstMerge) … $(a.lastMerge) ($(days_) days)");
    styledWriteln(i"Merges/week: $(perWeek)   Rebuild runs/week: $(rebuildsWeek)");
    styledWriteln(i"Green at head: $(a.green)/$(a.pullRequests) ($(greenPct))");
}

// ---------------------------------------------------------------------------
// Badges
// ---------------------------------------------------------------------------

/// Colour for a percentage, on shields.io's named scale. Thresholds rather
/// than a gradient: a badge is read at a glance, and "is this good" has about
/// four answers.
private string percentColor(double pct) @safe pure nothrow @nogc
{
    if (pct >= 90) return "brightgreen";
    if (pct >= 75) return "green";
    if (pct >= 50) return "yellow";
    return "orange";
}

/// One shields.io endpoint document.
///
/// The endpoint schema exists so a project can publish a number shields cannot
/// compute. That is exactly the case here: the share of merged pull requests
/// that were green is a ratio of two searches, and shields evaluates one URL.
string badgeJson(string label, string message, string color) @safe
{
    import std.json : JSONValue;

    JSONValue j;
    j["schemaVersion"] = 1;
    j["label"] = label;
    j["message"] = message;
    j["color"] = color;
    return j.toString;
}

@("merge_audit.badgeJson.isAShieldsEndpointDocument")
@safe unittest
{
    import std.json : parseJSON;

    auto j = parseJSON(badgeJson("merged PRs", "333", "blue"));
    assert(j["schemaVersion"].integer == 1);
    assert(j["label"].str == "merged PRs");
    assert(j["message"].str == "333");
}

@("merge_audit.percentColor.thresholds")
@safe pure nothrow @nogc unittest
{
    assert(percentColor(94.6) == "brightgreen");
    assert(percentColor(90.0) == "brightgreen");
    assert(percentColor(80.0) == "green");
    assert(percentColor(60.0) == "yellow");
    assert(percentColor(10.0) == "orange");
}

/// Write the two endpoint documents the README points at. Kept beside the
/// audit that computes them so the badge can never drift from the table.
void writeBadges(in MergeAudit a, string dir)
{
    import std.file : mkdirRecurse, write;
    import std.path : buildPath;

    mkdirRecurse(dir);
    write(dir.buildPath("merged-prs.json"),
        badgeJson("merged PRs", a.pullRequests.to!string, "blue"));
    write(dir.buildPath("merged-green.json"),
        badgeJson("merged with green CI", pctText(a.pct(a.green)), percentColor(a.pct(a.green))));
}
