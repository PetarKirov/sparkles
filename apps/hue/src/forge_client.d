/**
The seam's impure edge: the parts that touch the outside world.

$(MREF forge) and $(MREF forge_github) are pure — which is why their tests
never open a socket. This module holds the three things that cannot be: the
HTTP transport, the repository the user is standing in, and the token on their
disk. Keeping them here is what leaves the rest testable.

$(B libcurl is opt-in.) The `HueCurl` version (set by the configurations that
also declare `libs "curl"`) selects the real transport; without it — the
Android build, the unittest build — $(LREF fetchHttp) reports `unsupported`
rather than not existing, so everything above still compiles and every code
path above still runs.
*/
module forge_client;

import expected : err;

import forge : discoverToken, ForgeError, ForgeErrorKind, ForgeResult,
    HttpRequest, HttpResponse, parsePrTarget, PrRef, PullRequest,
    repoFromRemote, RepoId;
import forge_github : GitHubForge;

version (HueCurl)
    import std.net.curl : CurlException, CurlOption, HTTP;

/// How long a single forge request may take before it counts as a network
/// failure. A review tool that hangs is worse than one that says it cannot
/// reach the forge.
enum uint requestTimeoutSeconds = 30;

/**
The real transport (`DPR1`).

Every non-2xx status comes back as a $(LREF HttpResponse) rather than an
error: which failures matter and what they mean is the adapter's business
(`forge_github.classify`), not the wire's. Only a request that never got an
answer is an error here.
*/
ForgeResult!HttpResponse fetchHttp(in HttpRequest req) @system
{
    version (HueCurl)
    {
        import std.string : indexOf, strip;

        auto http = HTTP(req.url);
        http.method = HTTP.Method.get;
        foreach (h; req.headers)
        {
            const colon = h.indexOf(':');
            if (colon <= 0)
                continue;
            http.addRequestHeader(h[0 .. colon], h[colon + 1 .. $].strip);
        }
        http.handle.set(CurlOption.timeout, requestTimeoutSeconds);
        http.handle.set(CurlOption.followlocation, 1);

        char[] body_;
        int status;
        http.onReceive = (ubyte[] data) @trusted {
            body_ ~= cast(const(char)[]) data;
            return data.length;
        };
        http.onReceiveStatusLine = (HTTP.StatusLine line) {
            status = line.code;
        };

        try
            http.perform();
        catch (CurlException e)
            return err!HttpResponse(ForgeError(ForgeErrorKind.network, e.msg));
        return ForgeResult!HttpResponse(HttpResponse(status, body_.idup));
    }
    else
        return err!HttpResponse(ForgeError(ForgeErrorKind.unsupported,
            "this build has no HTTP transport (built without libcurl)"));
}

/// Whether this build can reach a forge at all — so a caller can say so
/// plainly instead of failing per request.
version (HueCurl)
    enum bool canFetch = true;
else
    enum bool canFetch = false;

/**
The forge repository the working directory belongs to.

`origin` first, then `upstream` — the fork convention, where `origin` is the
user's fork and `upstream` the repository PRs actually live in; either
resolves to a forge, and `origin` is the one they pushed to. An empty result
means "not a forge checkout", which the caller turns into a clear message
rather than a request.
*/
RepoId currentRepo() @safe
{
    import std.process : execute;
    import std.string : strip;

    foreach (remote; ["origin", "upstream"])
    {
        const r = execute(["git", "remote", "get-url", remote]);
        if (r.status != 0)
            continue;
        const id = repoFromRemote(r.output.strip);
        if (!id.empty)
            return id;
    }
    return RepoId.init;
}

/// The token for `host`, from the environment or `gh`'s config (`DPR1`).
/// Never prompts; an empty result is a legitimate unauthenticated client.
string tokenFor(scope const(char)[] host) @safe
{
    import std.file : exists, readText;
    import std.process : environment;

    import sparkles.core_cli.common_dirs : configDir;

    return discoverToken(GitHubForge.tokenEnvNames, host,
        (string name) @safe => environment.get(name, ""),
        (string path) @safe {
            try
                return path.exists ? readText(path) : "";
            catch (Exception)
                return "";
        },
        () @safe {
            try
                return configDir();
            catch (Exception)
                return "";
        });
}

/// A fetched pull request plus the unified patch its files assemble into.
struct FetchedPr
{
    PullRequest pr;
    RepoId repo;
    string patch;
}

/**
`hue --pr <number|url>`, end to end (`DPR1`).

Resolves the target against the current checkout, picks the adapter by host,
discovers a token, fetches, and assembles the files into the patch the diff
pipeline already reads. Every failure on the way is a $(LREF ForgeError) with
a kind, so the shell can say something useful (`DPR6`).
*/
ForgeResult!FetchedPr fetchPullRequest(string target) @system
{
    import forge : assemblePatch;

    auto ref_ = parsePrTarget(target, currentRepo());
    if (ref_.hasError)
        return err!FetchedPr(ref_.error);
    const pr = ref_.value;

    if (!GitHubForge.handles(pr.repo.host))
        return err!FetchedPr(ForgeError(ForgeErrorKind.unknownRemote,
            pr.repo.host ~ " has no adapter yet (GitHub is the only one)"));
    if (!canFetch)
        return err!FetchedPr(ForgeError(ForgeErrorKind.unsupported,
            "this build has no HTTP transport (built without libcurl)"));

    auto forge = GitHubForge(token: tokenFor(pr.repo.host));
    auto fetched = forge.pullRequest(pr, (in HttpRequest req) => fetchHttp(req));
    if (fetched.hasError)
        return err!FetchedPr(fetched.error);

    return ForgeResult!FetchedPr(FetchedPr(fetched.value, pr.repo,
        assemblePatch(fetched.value.files)));
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("forge_client.fetchPullRequest.refusesBeforeItReaches")
@system unittest
{
    // The failures that must never become a request: an unparseable target,
    // and a host no adapter claims. Both are decided locally, so this test
    // needs no network whatever the build.
    auto bad = fetchPullRequest("not-a-pr-target");
    assert(bad.hasError && bad.error.kind == ForgeErrorKind.unknownRemote);

    auto foreign = fetchPullRequest("https://bitbucket.org/o/r/pull/1");
    assert(foreign.hasError);
    assert(foreign.error.kind == ForgeErrorKind.unknownRemote
        || foreign.error.kind == ForgeErrorKind.unsupported);
}

@("forge_client.fetchHttp.saysSoWhenTheBuildCannot")
@system unittest
{
    // The unittest configuration does not link libcurl, so this is the
    // offline arm — and it must be a clear refusal, not a crash.
    static if (!canFetch)
    {
        auto res = fetchHttp(HttpRequest("https://example.invalid/", null));
        assert(res.hasError && res.error.kind == ForgeErrorKind.unsupported);
    }
}
