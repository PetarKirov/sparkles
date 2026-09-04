/++
`ci --report-link-rot` — keep one standing issue in step with the link sweep.

Link rot is a condition, not an event. The URLs in this repository point at
other people's servers, and a few of the ~15k are always moved, retired, or
rate-limiting today; that is worth fixing and worth knowing about, but it is
not a verdict on the code and must not be what a visitor sees first. So the
nightly sweep reports here instead of onto a commit.

The reporting shape follows from the same observation. One issue per failing
run would file a new one every night for the same three dead links, which
trains a reader to ignore exactly the thing being reported. Instead there is a
single issue, identified by its title: a failing sweep creates it or rewrites
its body, and a passing sweep closes it. It therefore always describes the
current state, and its absence is itself the "links are fine" signal.
+/
module link_rot;

import std.algorithm.iteration : filter;
import std.algorithm.searching : startsWith;
import std.array : array;
import std.conv : to;
import std.range.primitives : empty;

import sparkles.base.logger : info;

import sparkles.wired : fromJSON, WireOptional;

import ci_stats : failure, Result, success;

/// The title that identifies the standing issue. Matching on it exactly is
/// what makes the sweep idempotent, so it is a constant rather than an option:
/// a title that drifts silently starts a second issue instead of updating the
/// first.
enum rotIssueTitle = "Link rot: the nightly sweep found dead links";

private struct GhIssue
{
    int number;
    string title;
    string state;
}

private struct GhCreatedIssue
{
    int number;
}

/// What the sweep asked for, and what happened.
struct RotReport
{
    /// The sweep's verdict: `true` when links are dead.
    bool rotten;
    /// The issue acted on, or 0 when there was nothing to do.
    int issue;
    string action;
}

/// Trim a sweep log to what belongs in an issue body: the tail, which holds
/// lychee's error list and its summary line, fenced. The head is nix and prek
/// chatter, and GitHub caps an issue body at 64 KiB.
string rotIssueBody(string report, string runUrl, size_t maxBytes = 48 * 1024) @safe
{
    string tail = report;
    if (tail.length > maxBytes)
    {
        size_t cut = tail.length - maxBytes;
        // Do not open the fence mid-code-point, and start at a line boundary so
        // the excerpt reads as output rather than as debris.
        while (cut < tail.length && (tail[cut] & 0xC0) == 0x80)
            ++cut;
        while (cut < tail.length && tail[cut] != '\n')
            ++cut;
        tail = "…\n" ~ (cut < tail.length ? tail[cut + 1 .. $] : "");
    }

    return "The scheduled [link sweep](" ~ runUrl ~ ") found dead links.\n\n"
        ~ "This issue is rewritten by each failing sweep and closed by the first\n"
        ~ "passing one, so it always describes the current state.\n\n"
        ~ "```\n" ~ tail ~ "\n```\n";
}

@("link_rot.rotIssueBody.keepsTheTailAndFences")
@safe unittest
{
    import std.algorithm.searching : canFind, endsWith;

    const body_ = rotIssueBody("line one\nline two\nthe summary line", "https://run.invalid/1");
    assert(body_.canFind("https://run.invalid/1"));
    assert(body_.canFind("the summary line"));
    assert(body_.endsWith("```\n"));

    // An over-long report keeps its end — the summary — not its beginning.
    const long_ = rotIssueBody("head\n" ~ "x\n".to!string, "u", 4);
    assert(long_.canFind("…"));
}

/// Create, rewrite, or close the standing issue so it matches `rotten`.
Result!RotReport reportLinkRot(alias fetchJson)(
    string repo, string token, bool rotten, string report, string runUrl,
)
{
    import std.json : JSONValue;

    if (repo.length == 0)
        return failure!RotReport("--report-link-rot requires --repo owner/repo");

    string[string] headers;
    if (token.length)
        headers["Authorization"] = "Bearer " ~ token;

    const api = "https://api.github.com/repos/" ~ repo;

    // Search-free lookup: the open-issue list is short, and `search/issues` is
    // eventually consistent — a just-created issue can be missing from it for
    // minutes, which would file a duplicate on the very next run.
    auto open = fetchJson!(GhIssue[])(
        api ~ "/issues?state=open&per_page=100", "GET", null, headers);
    if (open.hasError)
        return failure!RotReport(open.error);

    auto standing = open.value.filter!(i => i.title == rotIssueTitle).array;

    if (!rotten)
    {
        if (standing.empty)
            return success(RotReport(action: "clean; no standing issue"));

        JSONValue close;
        close["state"] = "closed";
        const n = standing[0].number;
        auto res = fetchJson!GhIssue(
            api ~ "/issues/" ~ n.to!string, "PATCH", close.toString, headers);
        if (res.hasError)
            return failure!RotReport(res.error);
        return success(RotReport(issue: n, action: "closed #" ~ n.to!string ~ "; links are clean"));
    }

    JSONValue payload;
    payload["title"] = rotIssueTitle;
    payload["body"] = rotIssueBody(report, runUrl);

    if (!standing.empty)
    {
        const n = standing[0].number;
        auto res = fetchJson!GhIssue(
            api ~ "/issues/" ~ n.to!string, "PATCH", payload.toString, headers);
        if (res.hasError)
            return failure!RotReport(res.error);
        return success(RotReport(rotten: true, issue: n, action: "updated #" ~ n.to!string));
    }

    payload["labels"] = JSONValue(["documentation"]);
    auto res = fetchJson!GhCreatedIssue(api ~ "/issues", "POST", payload.toString, headers);
    if (res.hasError)
        return failure!RotReport(res.error);
    return success(RotReport(
        rotten: true, issue: res.value.number, action: "opened #" ~ res.value.number.to!string));
}

@("link_rot.reportLinkRot.cleanSweepWithNoIssueDoesNothing")
@system unittest
{
    // The fetcher answers the one GET with an empty issue list; any further
    // call would be a write, and a clean sweep with nothing open must not write.
    static auto fetch(T)(string url, string method = "GET", string = null, string[string] = null)
    {
        assert(method == "GET", "a clean sweep must not write");
        static if (is(T == GhIssue[]))
            return success!(GhIssue[])(null);
        else
            return failure!T("unexpected request: " ~ url);
    }

    auto res = reportLinkRot!fetch("o/r", "t", false, "", "u");
    assert(!res.hasError);
    assert(res.value.issue == 0 && !res.value.rotten);
}

@("link_rot.reportLinkRot.rottenSweepUpdatesTheStandingIssue")
@system unittest
{
    static auto fetch(T)(string url, string method = "GET", string body_ = null, string[string] = null)
    {
        static if (is(T == GhIssue[]))
            return success!(GhIssue[])([GhIssue(42, rotIssueTitle, "open")]);
        else static if (is(T == GhIssue))
        {
            assert(method == "PATCH", "an existing issue is edited, never re-filed");
            return success(GhIssue(42, rotIssueTitle, "open"));
        }
        else
            return failure!T("unexpected request: " ~ url);
    }

    auto res = reportLinkRot!fetch("o/r", "t", true, "7 errors", "u");
    assert(!res.hasError);
    assert(res.value.issue == 42 && res.value.action.startsWith("updated"));
}

@("link_rot.reportLinkRot.needsARepo")
@system unittest
{
    // `static`: DMD rejects a nested function template as an alias parameter
    // ("`never` is a nested function and cannot be accessed from ..."), because
    // the instantiation would need a context pointer. LDC accepts it, so this
    // only shows up on the dmd leg of the matrix.
    static auto never(T)(string, string = "GET", string = null, string[string] = null)
        => failure!T("the fetcher must not be reached");
    assert(reportLinkRot!never("", "t", true, "", "u").hasError);
}
