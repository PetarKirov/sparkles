/++
Commit→PR association via the GitHub GraphQL API (SPEC §6).

This repository merges PRs by rebase — no merge commits, no squash `(#N)`
subject suffixes — so the only reliable association between a commit on the
main branch and the pull request that introduced it is GitHub's
`associatedPullRequests` connection. The module parses the `origin` remote
into a $(LREF RepoSlug), builds batched aliased GraphQL queries, and decodes
the replies with `sparkles:wired`.

Pure parsing/building lives in standalone functions unit-tested on literal
strings; only the batching orchestrator invokes `gh`.
+/
module sparkles.release.pr;

import std.typecons : Nullable, nullable;

import sparkles.release.result : Result, success, failure;
import sparkles.release.stats : Commit;

@safe:

/// `owner`/`name` of a GitHub repository, parsed from a remote URL.
struct RepoSlug
{
    string owner;
    string name;
}

/// The merged PR (if any) that introduced one commit of the range.
struct PrRef
{
    string sha;    /// full commit OID (matches `Commit.sha`)
    uint number;   /// 0 ⇒ no merged PR (direct push / unpushed / unmerged only)
    string title;  /// empty when `number == 0`
}

/// Parses a GitHub remote URL into its owner/repo slug. Accepted forms
/// (SPEC §6): `git@github.com:Owner/repo(.git)`,
/// `https://github.com/Owner/repo(.git)`, and
/// `ssh://git@github.com/Owner/repo(.git)`; a trailing slash is tolerated.
/// Null for anything else (other hosts, missing components).
Nullable!RepoSlug parseRemoteUrl(string url) @safe pure nothrow @nogc
{
    string rest;
    if (!stripPrefix(url, "git@github.com:", rest)
        && !stripPrefix(url, "https://github.com/", rest)
        && !stripPrefix(url, "ssh://git@github.com/", rest))
        return Nullable!RepoSlug.init;

    if (rest.length && rest[$ - 1] == '/')
        rest = rest[0 .. $ - 1];
    string bare;
    if (!stripSuffix(rest, ".git", bare))
        bare = rest;

    // Exactly `owner/name`, both non-empty.
    size_t slash = size_t.max;
    foreach (i, c; bare)
        if (c == '/')
        {
            if (slash != size_t.max)
                return Nullable!RepoSlug.init;      // more than one slash
            slash = i;
        }
    if (slash == size_t.max || slash == 0 || slash + 1 == bare.length)
        return Nullable!RepoSlug.init;

    return nullable(RepoSlug(owner: bare[0 .. slash], name: bare[slash + 1 .. $]));
}

/// When `s` starts with `prefix`, sets `rest` to the remainder and returns true.
private bool stripPrefix(string s, string prefix, out string rest)
    @safe pure nothrow @nogc
{
    if (s.length < prefix.length || s[0 .. prefix.length] != prefix)
        return false;
    rest = s[prefix.length .. $];
    return true;
}

/// When `s` ends with `suffix`, sets `rest` to the front part and returns true.
private bool stripSuffix(string s, string suffix, out string rest)
    @safe pure nothrow @nogc
{
    if (s.length < suffix.length || s[$ - suffix.length .. $] != suffix)
        return false;
    rest = s[0 .. $ - suffix.length];
    return true;
}

// ---------------------------------------------------------------------------
// GraphQL association
// ---------------------------------------------------------------------------

/// Commits per `gh api graphql` call (SPEC §6). Far under GitHub's alias and
/// node limits; ~9 queries cover a 400-commit backlog.
enum associationBatchSize = 50;

/// One batched query: each commit becomes an alias `c<i>: object(oid: "…")`
/// asking for its associated PRs; owner/name stay GraphQL variables. The OIDs
/// are inlined, so each must be a full 40-hex SHA (they come from `git log`).
string buildAssociationQuery(const(string)[] shas) @safe pure
in (shas.length > 0)
{
    import std.array : appender;
    import std.conv : text;

    auto q = appender!string;
    q.put("query($owner: String!, $name: String!) { "
        ~ "repository(owner: $owner, name: $name) { ");
    foreach (i, sha; shas)
    {
        assert(isFullSha(sha), "not a full 40-hex commit SHA: " ~ sha);
        q.put(text("c", i, `: object(oid: "`, sha, `") { ... on Commit { `,
            "associatedPullRequests(first: 5) { nodes { number title mergedAt } } } } "));
    }
    q.put("} }");
    return q[];
}

private bool isFullSha(scope const(char)[] s) @safe pure nothrow @nogc
{
    if (s.length != 40)
        return false;
    foreach (c; s)
        if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f'))
            return false;
    return true;
}

/// One PR node of the `associatedPullRequests` connection. `mergedAt` is null
/// for open or closed-unmerged PRs.
private struct GqlPr
{
    uint number;
    string title;
    Nullable!string mergedAt;
}

private struct GqlPrConn
{
    GqlPr[] nodes;
}

private struct GqlCommitObj
{
    import sparkles.wired : WireName;

    @WireName("associatedPullRequests") GqlPrConn prs;
}

/// Decodes one batch reply, mapping alias `c<i>` back onto `shas[i]`. A null
/// commit object (OID unknown to GitHub — e.g. an unpushed local commit) and a
/// commit with no *merged* associated PR both yield `number 0`. GraphQL
/// `errors` alongside usable `data` are tolerated; a reply without `data` is
/// an error. (`@system`: the wired aggregate decode infers so.)
Result!(PrRef[]) parseAssociationReply(string json, const(string)[] shas) @system
{
    import std.conv : text;
    import std.json : JSONType, JSONValue;

    import sparkles.release.json_utils : parseJsonText;
    import sparkles.wired : fromJSON;

    auto domR = parseJsonText(json);
    if (domR.hasError)
        return failure!(PrRef[])("gh graphql reply: " ~ domR.error);
    auto dom = domR.value;

    if (dom.type != JSONType.object || "data" !in dom
        || dom["data"].type != JSONType.object
        || "repository" !in dom["data"]
        || dom["data"]["repository"].type != JSONType.object)
    {
        auto raw = json.length > 512 ? json[0 .. 512] ~ "…" : json;
        return failure!(PrRef[])("gh graphql reply carries no data: " ~ raw);
    }
    auto repo = dom["data"]["repository"];

    PrRef[] refs;
    refs.reserve(shas.length);
    foreach (i, sha; shas)
    {
        const aliasName = text("c", i);
        if (aliasName !in repo || repo[aliasName].type == JSONType.null_)
        {
            refs ~= PrRef(sha: sha, number: 0);
            continue;
        }
        auto decoded = fromJSON!GqlCommitObj(repo[aliasName]);
        if (decoded.hasError)
            return failure!(PrRef[])(
                "gh graphql reply for " ~ sha ~ ": " ~ decoded.error.msg);

        PrRef r = PrRef(sha: sha, number: 0);
        foreach (node; decoded.value.prs.nodes)
            if (!node.mergedAt.isNull)
            {
                r = PrRef(sha: sha, number: node.number, title: node.title);
                break;
            }
        refs ~= r;
    }
    return success(refs);
}

/// Associates every commit (oldest first) with the merged PR that introduced
/// it, batching `gh api graphql` calls. `progress(done, total)` fires after
/// each batch.
Result!(PrRef[]) associatePrs(const(Commit)[] commitsOldestFirst, RepoSlug slug,
    void delegate(size_t done, size_t total) @safe progress = null) @system
{
    import std.algorithm.comparison : min;
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.string : strip;

    import sparkles.core_cli.process_utils : runCaptured;

    PrRef[] all;
    all.reserve(commitsOldestFirst.length);
    for (size_t start = 0; start < commitsOldestFirst.length; start += associationBatchSize)
    {
        const end = min(start + associationBatchSize, commitsOldestFirst.length);
        auto shas = commitsOldestFirst[start .. end].map!(c => c.sha).array;

        auto r = runCaptured([
            "gh", "api", "graphql",
            "-f", "query=" ~ buildAssociationQuery(shas),
            "-f", "owner=" ~ slug.owner,
            "-f", "name=" ~ slug.name,
        ]);
        if (r.status != 0)
            return failure!(PrRef[])("gh api graphql failed: " ~ r.stderr.strip.idup);

        auto parsed = parseAssociationReply(r.stdout, shas);
        if (parsed.hasError)
            return parsed;
        all ~= parsed.value;

        if (progress !is null)
            progress(end, commitsOldestFirst.length);
    }
    return success(all);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("pr.parseRemoteUrl.acceptedForms")
@safe pure nothrow @nogc
unittest
{
    static immutable forms = [
        "git@github.com:PetarKirov/sparkles.git",
        "git@github.com:PetarKirov/sparkles",
        "https://github.com/PetarKirov/sparkles.git",
        "https://github.com/PetarKirov/sparkles",
        "https://github.com/PetarKirov/sparkles/",
        "ssh://git@github.com/PetarKirov/sparkles.git",
    ];
    foreach (url; forms)
    {
        const slug = parseRemoteUrl(url);
        assert(!slug.isNull);
        assert(slug.get.owner == "PetarKirov");
        assert(slug.get.name == "sparkles");
    }
}

@("pr.parseRemoteUrl.rejected")
@safe pure nothrow @nogc
unittest
{
    assert(parseRemoteUrl("git@gitlab.com:owner/repo.git").isNull);
    assert(parseRemoteUrl("https://example.com/owner/repo").isNull);
    assert(parseRemoteUrl("https://github.com/only-owner").isNull);
    assert(parseRemoteUrl("https://github.com/owner/repo/extra").isNull);
    assert(parseRemoteUrl("git@github.com:/repo.git").isNull);
    assert(parseRemoteUrl("git@github.com:owner/.git").isNull);
    assert(parseRemoteUrl("").isNull);
}

version (unittest)
{
    // Deterministic fake OIDs for the query/reply tests.
    private enum shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private enum shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    private enum shaC = "cccccccccccccccccccccccccccccccccccccccc";
}

@("pr.buildAssociationQuery.aliasesAndOids")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const q = buildAssociationQuery([shaA, shaB]);
    assert(q.canFind(`c0: object(oid: "` ~ shaA ~ `")`));
    assert(q.canFind(`c1: object(oid: "` ~ shaB ~ `")`));
    assert(q.canFind("associatedPullRequests(first: 5)"));
    assert(q.canFind("$owner: String!"));
    assert(q.canFind("repository(owner: $owner, name: $name)"));
}

@("pr.parseAssociationReply.happyPathAndNoPr")
@system unittest
{
    // c0 has one merged PR; c1 has none at all.
    const json = `{"data": {"repository": {
        "c0": {"associatedPullRequests": {"nodes":
            [{"number": 89, "title": "feat(x): y", "mergedAt": "2026-07-09T21:36:13Z"}]}},
        "c1": {"associatedPullRequests": {"nodes": []}}
    }}}`;
    auto r = parseAssociationReply(json, [shaA, shaB]);
    assert(r.hasValue);
    assert(r.value == [
        PrRef(sha: shaA, number: 89, title: "feat(x): y"),
        PrRef(sha: shaB, number: 0),
    ]);
}

@("pr.parseAssociationReply.nullObjectForUnknownOid")
@system unittest
{
    const json = `{"data": {"repository": {"c0": null}}}`;
    auto r = parseAssociationReply(json, [shaA]);
    assert(r.hasValue);
    assert(r.value == [PrRef(sha: shaA, number: 0)]);
}

@("pr.parseAssociationReply.prefersMergedPr")
@system unittest
{
    // An open PR (null mergedAt) precedes the merged one; the merged one wins.
    const json = `{"data": {"repository": {
        "c0": {"associatedPullRequests": {"nodes": [
            {"number": 91, "title": "open pr", "mergedAt": null},
            {"number": 88, "title": "the real one", "mergedAt": "2026-07-01T00:00:00Z"}
        ]}}
    }}}`;
    auto r = parseAssociationReply(json, [shaA]);
    assert(r.hasValue);
    assert(r.value[0].number == 88);
    assert(r.value[0].title == "the real one");
}

@("pr.parseAssociationReply.openPrOnlyMeansNoPr")
@system unittest
{
    const json = `{"data": {"repository": {
        "c0": {"associatedPullRequests": {"nodes":
            [{"number": 91, "title": "open pr", "mergedAt": null}]}}
    }}}`;
    auto r = parseAssociationReply(json, [shaA]);
    assert(r.hasValue);
    assert(r.value[0].number == 0);
}

@("pr.parseAssociationReply.toleratesErrorsArrayWithData")
@system unittest
{
    const json = `{"errors": [{"message": "partial"}], "data": {"repository": {
        "c0": {"associatedPullRequests": {"nodes": []}}
    }}}`;
    auto r = parseAssociationReply(json, [shaA]);
    assert(r.hasValue);
    assert(r.value[0].number == 0);
}

@("pr.parseAssociationReply.missingDataIsError")
@system unittest
{
    assert(parseAssociationReply(`{"errors": [{"message": "boom"}]}`, [shaA]).hasError);
    assert(parseAssociationReply(`not json`, [shaA]).hasError);
    assert(parseAssociationReply(`{"data": null}`, [shaA]).hasError);
}

@("pr.parseAssociationReply.missingAliasMeansNoPr")
@system unittest
{
    // Defensive: an alias the server did not echo back resolves to "no PR".
    const json = `{"data": {"repository": {
        "c0": {"associatedPullRequests": {"nodes": []}}
    }}}`;
    auto r = parseAssociationReply(json, [shaA, shaC]);
    assert(r.hasValue);
    assert(r.value[1] == PrRef(sha: shaC, number: 0));
}
