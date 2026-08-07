/**
The GitHub adapter (`DPR1`) — the seam's first implementation, and nothing
above it knows it exists.

Fetch is native: the REST API composed and decoded here, in D, with no `gh`
binary in the picture. (Reading `gh`'s `hosts.yml` for a token, in
$(MREF forge), is a config file being read — hue never runs the tool.)

Decoding goes through `sparkles:wired`, which walks the declared fields and
ignores everything else — and a GitHub PR payload has upwards of eighty keys
hue has no use for. The structs below are therefore a statement of what hue
needs, not a model of the API.
*/
module forge_github;

import expected : err;

import forge : Comment, CommentThread, ForgeError, ForgeErrorKind,
    ForgeResult, HttpRequest, HttpResponse, isForge, PrFile, PrRef,
    PullRequest, RepoId, ThreadSide, Transport;

import sparkles.wired.policy : CaseStyle, WireCase, WireInvalid,
    WireName, WireOptional;

/// GitHub's own page size for the files endpoint, and the cap on how many
/// pages hue will walk. 3000 files is GitHub's own hard limit for a PR diff;
/// past it the API itself truncates, and so does the review.
enum uint filesPerPage = 100;
/// ditto
enum uint maxFilePages = 30;

/**
The adapter.

`handles` claims a host — `github.com` plus GitHub Enterprise hosts, which a
user names through configuration rather than by hue guessing. A value type
with its own `apiBase`, so an Enterprise instance is a different instance of
the same adapter, never a branch inside it.
*/
struct GitHubForge
{
    /// `https://api.github.com`, or an Enterprise instance's `/api/v3` root.
    string apiBase = "https://api.github.com";
    /// The token to present. Empty means unauthenticated — which works for
    /// public repositories, at a much lower rate limit.
    string token;

    /// The hosts this adapter claims by default.
    static bool handles(scope const(char)[] host) @safe pure nothrow @nogc
        => host == "github.com";

    /// The environment variables to consult, in order (`DPR1`).
    static immutable string[] tokenEnvNames = ["GITHUB_TOKEN", "GH_TOKEN"];

    // ── Capabilities (`DPR7`), declared by presence ──────────────────────────

    /// GitHub renders a ` ```suggestion ` fence in a review comment as an
    /// applyable suggestion (`DCM4`'s first emitter).
    enum suggestionFence = "suggestion";

    /**
    `DPR3`: the PR's review conversations, with their resolved state.

    GraphQL rather than REST, and not by preference: REST's review comments
    carry no notion of a resolved THREAD at all — only individual comments and
    `in_reply_to_id` links to rebuild the grouping from. Resolution is the
    thing that decides whether a conversation folds to a badge or demands
    attention, so a view built on REST would have to show every settled
    argument at full size forever.

    That costs authentication: GitHub's GraphQL endpoint refuses anonymous
    requests entirely, where its REST endpoints serve public repositories. So
    a tokenless session still reads the diff and simply has no threads —
    `noAuth`, which the caller can report once rather than per thread.
    */
    ForgeResult!(CommentThread[]) reviewThreads(in PrRef pr, scope Transport http)
        @system
    {
        import std.conv : text;

        if (token.length == 0)
            return err!(CommentThread[])(ForgeError(ForgeErrorKind.noAuth,
                "review threads need a token (GitHub's GraphQL API refuses "
                ~ "anonymous requests)"));

        const query = `{"query":"query($o:String!,$n:String!,$p:Int!){`
            ~ `repository(owner:$o,name:$n){pullRequest(number:$p){`
            ~ `reviewThreads(first:100){nodes{isResolved isOutdated path line `
            ~ `diffSide comments(first:50){nodes{body createdAt `
            ~ `author{login}}}}}}}}","variables":{"o":"` ~ pr.repo.owner
            ~ `","n":"` ~ pr.repo.name ~ `","p":` ~ text(pr.number) ~ `}}`;

        auto res = post(graphqlUrl, query, http);
        if (res.hasError)
            return err!(CommentThread[])(res.error);
        return decodeThreads(res.value);
    }

    /// The GraphQL endpoint beside `apiBase`. On github.com the REST root is
    /// `api.github.com` and GraphQL hangs off the same host; an Enterprise
    /// instance puts it beside `/api/v3` as `/api/graphql`.
    private string graphqlUrl() const @safe pure
    {
        import std.string : endsWith;

        return apiBase.endsWith("/api/v3")
            ? apiBase[0 .. $ - 3] ~ "graphql" : apiBase ~ "/graphql";
    }

    /// One POST, with the failure vocabulary applied (`DPR6`).
    private ForgeResult!string post(string url, string body_, scope Transport http)
        @system
    {
        string[] headers = [
            "Accept: application/vnd.github+json",
            "Content-Type: application/json",
            "User-Agent: hue",
            "Authorization: Bearer " ~ token,
        ];
        auto res = http(HttpRequest(url, headers, body_));
        if (res.hasError)
            return err!string(res.error);
        return classify(res.value, url, true);
    }

    /**
    Fetches a pull request: metadata, description and file list.

    Two calls, because that is what the API offers — the PR itself, then its
    files, paginated. Both go through `http`, so this whole function is
    exercised without a network.
    */
    ForgeResult!PullRequest pullRequest(in PrRef pr, scope Transport http) @system
    {
        import std.conv : text;

        const base = apiBase ~ "/repos/" ~ pr.repo.owner ~ "/" ~ pr.repo.name
            ~ "/pulls/" ~ text(pr.number);

        auto meta = fetch(base, http);
        if (meta.hasError)
            return err!PullRequest(meta.error);

        auto decoded = decodePullRequest(meta.value);
        if (decoded.hasError)
            return decoded;

        auto out_ = decoded.value;
        for (uint page = 1; page <= maxFilePages; ++page)
        {
            auto files = fetch(text(base, "/files?per_page=", filesPerPage,
                "&page=", page), http);
            if (files.hasError)
                return err!PullRequest(files.error);
            auto batch = decodeFiles(files.value);
            if (batch.hasError)
                return err!PullRequest(batch.error);
            out_.files ~= batch.value;
            // A short page is the last page — GitHub sends a `Link` header
            // too, but the length tells us the same thing without one.
            if (batch.value.length < filesPerPage)
                break;
        }
        return typeof(return)(out_);
    }

    /// One GET, with the failure vocabulary applied (`DPR6`).
    private ForgeResult!string fetch(string url, scope Transport http) @system
    {
        string[] headers = [
            "Accept: application/vnd.github+json",
            "X-GitHub-Api-Version: 2022-11-28",
            "User-Agent: hue",
        ];
        if (token.length)
            headers ~= "Authorization: Bearer " ~ token;

        auto res = http(HttpRequest(url, headers));
        if (res.hasError)
            return err!string(res.error);
        return classify(res.value, url, token.length != 0);
    }
}

static assert(isForge!GitHubForge,
    "the first adapter must satisfy the seam it defines");

/**
An HTTP status turned into the failure vocabulary (`DPR6`).

The distinctions that matter to a user: a 401/403 with no token is "log in",
the same status WITH a token is "this token cannot see it", and a 403 whose
rate-limit counter is exhausted is neither — it is "wait". Collapsing these
into "request failed" is what makes a tool feel broken.
*/
ForgeResult!string classify(in HttpResponse res, string url, bool authenticated)
    @safe pure
{
    import std.string : indexOf;

    if (res.status >= 200 && res.status < 300)
        return ForgeResult!string(res.body_.idup);

    static string reason(in HttpResponse r) @safe pure
    {
        // GitHub puts a human-readable `"message"` in every error body.
        const at = r.body_.indexOf("\"message\"");
        if (at < 0)
            return null;
        const colon = r.body_[at .. $].indexOf(':');
        if (colon < 0)
            return null;
        const(char)[] rest = r.body_[at + colon + 1 .. $];
        const open = rest.indexOf('"');
        if (open < 0)
            return null;
        rest = rest[open + 1 .. $];
        const close = rest.indexOf('"');
        return close < 0 ? null : rest[0 .. close].idup;
    }

    const msg = reason(res);
    const detail = msg.length ? msg : url;

    switch (res.status)
    {
        case 401:
            return err!string(ForgeError(ForgeErrorKind.noAuth, detail));
        case 403:
            // A 403 is GitHub's rate-limit answer as well as its permission
            // answer; the body says which.
            if (msg.indexOf("rate limit") >= 0
                || msg.indexOf("abuse") >= 0)
                return err!string(ForgeError(ForgeErrorKind.rateLimited,
                    detail));
            return err!string(ForgeError(authenticated
                ? ForgeErrorKind.notFound : ForgeErrorKind.noAuth, detail));
        case 429:
            return err!string(ForgeError(ForgeErrorKind.rateLimited, detail));
        case 404:
            // A private PR looks exactly like a missing one to an
            // unauthenticated client, so say the useful thing.
            return err!string(ForgeError(authenticated
                ? ForgeErrorKind.notFound : ForgeErrorKind.noAuth,
                authenticated ? detail
                    : detail ~ " (or it is private and no token was found)"));
        default:
            if (res.status >= 500)
                return err!string(ForgeError(ForgeErrorKind.network,
                    "the forge returned " ~ statusText(res.status)));
            return err!string(ForgeError(ForgeErrorKind.malformed,
                "unexpected status " ~ statusText(res.status)));
    }
}

private string statusText(int status) @safe pure
{
    import std.conv : text;

    return text(status);
}

// ── The wire shapes hue actually consumes ───────────────────────────────────

@WireCase(CaseStyle.snakeCase)
private struct GhUser
{
    string login;
}

@WireCase(CaseStyle.snakeCase)
private struct GhRef
{
    @WireOptional() string ref_;
    @WireOptional() string sha;
}

@WireCase(CaseStyle.snakeCase)
private struct GhPull
{
    uint number;
    @WireOptional() string title;
    @WireOptional() @WireName("body") string body_;
    @WireOptional() string state;
    @WireOptional() bool draft;
    @WireOptional() bool merged;
    @WireOptional() GhUser user;
    @WireOptional() GhRef base;
    @WireOptional() GhRef head;
}

@WireCase(CaseStyle.snakeCase)
private struct GhFile
{
    string filename;
    @WireOptional() string previousFilename;
    @WireOptional() string status;
    @WireOptional() uint additions;
    @WireOptional() uint deletions;
    @WireOptional() string patch;
}

/// Decodes the PR object. Everything but `number` is optional, so a payload
/// shaped differently by an Enterprise version degrades to a thinner header
/// rather than to a failed review.
ForgeResult!PullRequest decodePullRequest(scope const(char)[] json) @safe
{
    auto res = parse!GhPull(json);
    if (res.hasError)
        return err!PullRequest(res.error);

    const p = res.value;
    PullRequest out_ = {
        number: p.number,
        title: p.title,
        description: p.body_,
        author: p.user.login,
        // GitHub reports a merged PR as `state: "closed"` plus `merged: true`;
        // a reviewer wants the distinction.
        state: p.merged ? "merged" : p.state,
        draft: p.draft,
        baseRef: p.base.ref_,
        headRef: p.head.ref_,
        baseSha: p.base.sha,
        headSha: p.head.sha,
    };
    return typeof(return)(out_);
}

/// ditto, for one page of the files endpoint.
ForgeResult!(PrFile[]) decodeFiles(scope const(char)[] json) @safe
{
    auto res = parse!(GhFile[])(json);
    if (res.hasError)
        return err!(PrFile[])(res.error);

    PrFile[] out_;
    foreach (ref f; res.value)
        out_ ~= PrFile(
            path: f.filename,
            previousPath: f.previousFilename,
            status: f.status.length ? f.status : "modified",
            additions: f.additions,
            deletions: f.deletions,
            patch: f.patch,
        );
    return typeof(return)(out_);
}

// GraphQL answers in camelCase, which is D's own spelling — so unlike the
// REST shapes above these need no recasing, only the `body` keyword dodge.

private struct GqlAuthor
{
    @WireOptional() string login;
}

private struct GqlComment
{
    @WireOptional() GqlAuthor author;
    @WireOptional() @WireName("body") string body_;
    @WireOptional() string createdAt;
}

private struct GqlCommentNodes
{
    @WireOptional() GqlComment[] nodes;
}

private struct GqlThread
{
    @WireOptional() bool isResolved;
    @WireOptional() bool isOutdated;
    @WireOptional() string path;
    /// Null for a thread whose line no longer exists. That is not a
    /// malformed answer, it is exactly what `isOutdated` reports — so the
    /// field takes the default rather than rejecting the whole payload and
    /// costing the reviewer every OTHER thread in it.
    @WireOptional(onInvalid: WireInvalid.useDefault) uint line;
    @WireOptional() string diffSide;
    @WireOptional() GqlCommentNodes comments;
}

private struct GqlThreadNodes
{
    @WireOptional() GqlThread[] nodes;
}

private struct GqlPullRequest
{
    @WireOptional() GqlThreadNodes reviewThreads;
}

private struct GqlRepository
{
    @WireOptional() GqlPullRequest pullRequest;
}

private struct GqlData
{
    @WireOptional() GqlRepository repository;
}

private struct GqlResponse
{
    @WireOptional() GqlData data;
}

/**
Decodes a `reviewThreads` GraphQL answer (`DPR3`).

A GraphQL error arrives with HTTP 200 and an `errors` array, so a decode that
only looked at the status would report success on a refusal. An answer with no
`repository` is that case: it becomes a `malformed` failure rather than an
empty thread list, because "no threads" and "the query was rejected" must not
look the same to a reviewer.
*/
ForgeResult!(CommentThread[]) decodeThreads(scope const(char)[] json) @safe
{
    import std.string : indexOf;

    auto res = parse!GqlResponse(json);
    if (res.hasError)
        return err!(CommentThread[])(res.error);

    const nodes = res.value.data.repository.pullRequest.reviewThreads.nodes;
    if (nodes.length == 0 && json.indexOf(`"errors"`) >= 0)
        return err!(CommentThread[])(ForgeError(ForgeErrorKind.malformed,
            "the forge rejected the thread query"));

    CommentThread[] out_;
    foreach (ref t; nodes)
    {
        CommentThread thread = {
            path: t.path,
            line: t.line,
            // GraphQL says LEFT for the old side; anything else is the new
            // one, which is also the right default for a missing field.
            side: t.diffSide == "LEFT" ? ThreadSide.oldSide : ThreadSide.newSide,
            resolved: t.isResolved,
            outdated: t.isOutdated,
        };
        foreach (ref c; t.comments.nodes)
            thread.comments ~= Comment(c.author.login, c.body_, c.createdAt);
        out_ ~= thread;
    }
    return ForgeResult!(CommentThread[])(out_);
}

private ForgeResult!T parse(T)(scope const(char)[] json) @safe
{
    import std.json : JSONValue, parseJSON;
    import sparkles.wired.json : fromJSON;

    JSONValue root;
    try
        root = parseJSON(json);
    catch (Exception e)
        return err!T(ForgeError(ForgeErrorKind.malformed,
            "invalid JSON: " ~ e.msg));

    auto res = (() @trusted => fromJSON!T(root))();
    if (res.hasError)
        return err!T(ForgeError(ForgeErrorKind.malformed,
            (() @trusted => res.error.toString())()));
    return ForgeResult!T(res.value);
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("forge_github.decodePullRequest.takesWhatItNeedsAndIgnoresTheRest")
@safe unittest
{
    // A trimmed but real-shaped payload: the eighty keys hue does not model
    // must pass through harmlessly, which is the whole reason for wired here.
    enum json = `{
        "number": 247, "title": "V6 — the rendered-preview markdown diff",
        "body": "## Summary\n\nThe fourth noise layer.",
        "state": "closed", "merged": true, "draft": false,
        "user": {"login": "PetarKirov", "id": 12345, "type": "User"},
        "base": {"ref": "main", "sha": "abc123", "repo": {"id": 1}},
        "head": {"ref": "feat/diff/v6-preview", "sha": "def456"},
        "additions": 900, "deletions": 20, "changed_files": 8,
        "_links": {"self": {"href": "…"}}
    }`;
    auto res = decodePullRequest(json);
    assert(!res.hasError, res.hasError ? res.error.toString() : "");

    const pr = res.value;
    assert(pr.number == 247);
    assert(pr.author == "PetarKirov");
    assert(pr.baseRef == "main" && pr.headRef == "feat/diff/v6-preview");
    assert(pr.headSha == "def456");
    // A merged PR is reported `closed` + `merged`; a reviewer wants the word
    // that actually describes it.
    assert(pr.state == "merged");
    assert(pr.description.length != 0, "the description is rendered markdown");
}

@("forge_github.decodeFiles.mapsTheForgeVocabulary")
@safe unittest
{
    enum json = `[
        {"filename": "src/a.d", "status": "modified", "additions": 3,
            "deletions": 1, "patch": "@@ -1 +1 @@\n-a\n+b\n", "sha": "…"},
        {"filename": "src/new.d", "previous_filename": "src/old.d",
            "status": "renamed", "additions": 0, "deletions": 0},
        {"filename": "logo.png", "status": "modified"}
    ]`;
    auto res = decodeFiles(json);
    assert(!res.hasError);

    const files = res.value;
    assert(files.length == 3);
    assert(files[0].path == "src/a.d" && files[0].additions == 3);
    assert(files[1].previousPath == "src/old.d" && files[1].status == "renamed");
    // No `patch` key at all (binary): the file still exists in the list.
    assert(files[2].patch.length == 0 && files[2].path == "logo.png");
}

@("forge_github.classify.tellsTheFailuresApart")
@safe unittest
{
    import forge : ForgeErrorKind;

    static ForgeErrorKind kindOf(int status, string body_, bool auth) @safe
    {
        auto r = classify(HttpResponse(status, body_), "u", auth);
        assert(r.hasError);
        return r.error.kind;
    }

    assert(!classify(HttpResponse(200, "{}"), "u", true).hasError);

    // The distinction that matters most: the same 404 means different things
    // with and without a token, and telling a user "not found" when the real
    // answer is "log in" sends them looking in the wrong place.
    assert(kindOf(404, `{"message":"Not Found"}`, true)
        == ForgeErrorKind.notFound);
    assert(kindOf(404, `{"message":"Not Found"}`, false)
        == ForgeErrorKind.noAuth);
    assert(kindOf(401, `{"message":"Bad credentials"}`, true)
        == ForgeErrorKind.noAuth);

    // A 403 is both GitHub's permission answer and its rate-limit answer.
    assert(kindOf(403, `{"message":"API rate limit exceeded for …"}`, true)
        == ForgeErrorKind.rateLimited);
    assert(kindOf(403, `{"message":"Resource not accessible"}`, true)
        == ForgeErrorKind.notFound);
    assert(kindOf(429, "{}", true) == ForgeErrorKind.rateLimited);

    assert(kindOf(502, "", true) == ForgeErrorKind.network);
    assert(kindOf(418, "", true) == ForgeErrorKind.malformed);

    // The forge's own message survives into what the user reads.
    auto r = classify(HttpResponse(401, `{"message":"Bad credentials"}`), "u",
        true);
    assert(r.error.toString() == "no forge credentials: Bad credentials");
}

@("forge_github.pullRequest.walksThePagesWithoutANetwork")
@system unittest
{
    import expected : ok;
    import forge : HttpRequest;

    // The transport seam earning its keep: the whole fetch path — URL
    // composition, headers, pagination, decode — under test, offline.
    string[] asked;
    auto fake = delegate ForgeResult!HttpResponse(in HttpRequest req) @system {
        asked ~= req.url;
        if (req.url.length > 6 && req.url[$ - 6 .. $] == "/pulls")
            return ForgeResult!HttpResponse(HttpResponse(200, "{}"));
        if (req.url.length >= 8 && req.url[0 .. 8] == "https://"
            && req.url[$ - 1] == '1' && req.url[$ - 7 .. $] == "&page=1")
            return ForgeResult!HttpResponse(HttpResponse(200,
                `[{"filename":"a.d","status":"modified","patch":"@@ -1 +1 @@\n-a\n+b\n"}]`));
        if (req.url[$ - 7 .. $] == "&page=2")
            return ForgeResult!HttpResponse(HttpResponse(200, `[]`));
        return ForgeResult!HttpResponse(HttpResponse(200,
            `{"number":7,"title":"T","state":"open","user":{"login":"u"},
            "base":{"ref":"main"},"head":{"ref":"topic"}}`));
    };

    auto gh = GitHubForge(token: "t");
    auto res = gh.pullRequest(PrRef(RepoId("github.com", "o", "r"), 7), fake);
    assert(!res.hasError, res.hasError ? res.error.toString() : "");
    assert(res.value.number == 7 && res.value.author == "u");
    assert(res.value.files.length == 1 && res.value.files[0].path == "a.d");

    // One page short of full ends the walk: no request for page 2.
    assert(asked.length == 2, "metadata, then one page of files");
    assert(asked[0] == "https://api.github.com/repos/o/r/pulls/7");
}

@("forge_github.pullRequest.aFailedFetchStopsTheWholeThing")
@system unittest
{
    import forge : ForgeErrorKind, HttpRequest;

    auto refuse = delegate ForgeResult!HttpResponse(in HttpRequest req) @system {
        return ForgeResult!HttpResponse(HttpResponse(403,
            `{"message":"API rate limit exceeded"}`));
    };

    auto gh = GitHubForge();
    auto res = gh.pullRequest(PrRef(RepoId("github.com", "o", "r"), 1), refuse);
    assert(res.hasError && res.error.kind == ForgeErrorKind.rateLimited,
        "a rate limit must survive as itself, not as a generic failure");
}

@("forge_github.decodeThreads.groupsWhatTheReviewerMustRead")
@safe unittest
{
    import forge : ThreadSide;

    // A real-shaped answer: one live thread on the new side, one resolved,
    // and one outdated whose line GitHub reports as null.
    enum json = `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
        {"isResolved": false, "isOutdated": false, "path": "src/a.d",
            "line": 42, "diffSide": "RIGHT", "comments": {"nodes": [
                {"body": "why this way?", "createdAt": "2026-08-07T10:00:00Z",
                    "author": {"login": "reviewer"}},
                {"body": "because X", "createdAt": "2026-08-07T11:00:00Z",
                    "author": {"login": "author"}}]}},
        {"isResolved": true, "isOutdated": false, "path": "src/b.d",
            "line": 7, "diffSide": "LEFT", "comments": {"nodes": [
                {"body": "settled", "createdAt": "2026-08-06T09:00:00Z",
                    "author": {"login": "reviewer"}}]}},
        {"isResolved": false, "isOutdated": true, "path": "src/c.d",
            "line": null, "diffSide": "RIGHT", "comments": {"nodes": [
                {"body": "stale", "createdAt": "2026-08-05T09:00:00Z",
                    "author": {"login": "reviewer"}}]}}]}}}}}`;

    auto res = decodeThreads(json);
    assert(!res.hasError, res.hasError ? res.error.toString() : "");
    const threads = res.value;
    assert(threads.length == 3);

    assert(threads[0].path == "src/a.d" && threads[0].line == 42);
    assert(threads[0].side == ThreadSide.newSide && !threads[0].resolved);
    assert(threads[0].comments.length == 2);
    assert(threads[0].comments[1].author == "author");

    // A comment on a removed line belongs to the OLD text; anchoring it to
    // the new one would attach it to a line its author never saw.
    assert(threads[1].side == ThreadSide.oldSide && threads[1].resolved);

    // A null line decodes to zero rather than failing the whole answer —
    // which is precisely what `isOutdated` is reporting.
    assert(threads[2].outdated && threads[2].line == 0);
}

@("forge_github.decodeThreads.aRejectedQueryIsNotAnEmptyList")
@safe unittest
{
    // GraphQL answers a refusal with HTTP 200 and an `errors` array, so a
    // decode that trusted the status would report success. "No threads" and
    // "the query was rejected" must not look the same to a reviewer.
    enum refused = `{"data":{"repository":null},"errors":[
        {"message":"Could not resolve to a Repository."}]}`;
    auto res = decodeThreads(refused);
    assert(res.hasError && res.error.kind == ForgeErrorKind.malformed);

    // A genuinely empty list stays a success.
    enum empty = `{"data":{"repository":{"pullRequest":{"reviewThreads":
        {"nodes":[]}}}}}`;
    auto none = decodeThreads(empty);
    assert(!none.hasError && none.value.length == 0);
}

@("forge_github.reviewThreads.needsATokenAndSaysSo")
@system unittest
{
    import forge : HttpRequest;

    // Unauthenticated: GitHub's GraphQL endpoint refuses outright, so this
    // must be reported once — not attempted and failed per thread.
    auto never = delegate ForgeResult!HttpResponse(in HttpRequest req) @system {
        assert(false, "an anonymous thread query must not be sent");
    };
    auto anon = GitHubForge();
    auto res = anon.reviewThreads(PrRef(RepoId("github.com", "o", "r"), 1),
        never);
    assert(res.hasError && res.error.kind == ForgeErrorKind.noAuth);

    // With a token the query is a POST carrying a body, to the GraphQL root.
    string url, body_;
    auto capture = delegate ForgeResult!HttpResponse(in HttpRequest req) @system {
        url = req.url;
        body_ = req.body_;
        return ForgeResult!HttpResponse(HttpResponse(200,
            `{"data":{"repository":{"pullRequest":{"reviewThreads":
                {"nodes":[]}}}}}`));
    };
    auto gh = GitHubForge(token: "t");
    assert(!gh.reviewThreads(PrRef(RepoId("github.com", "o", "r"), 9),
        capture).hasError);
    assert(url == "https://api.github.com/graphql");
    assert(body_.length != 0, "a GraphQL query travels as a body");

    import std.algorithm.searching : canFind;

    assert(body_.canFind(`"p":9`) && body_.canFind(`"n":"r"`),
        "the variables name the PR being asked about");
}
