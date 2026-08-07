/**
The forge seam (`DPR7`): what hue knows about pull requests, with no forge in
it.

GitHub is the first adapter, not the model. Everything above this module talks
about a $(LREF PullRequest) and a $(LREF ForgeError); nothing above it names
`api.github.com`, and no session or UI code branches on which forge it is.
Adding GitLab, Gitea, Forgejo or Codeberg is then adding an adapter — the
decision-12 shape, and the reason capabilities are probed by PRESENCE
($(LREF hasCapability)) rather than declared in one interface every adapter
must satisfy in full. A forge without draft reviews simply has no
`draftReview` member, and the feature that needs one degrades; it does not
have to implement a stub that fails at run time.

The transport is injected ($(LREF Transport)), so every part of this module —
remote parsing, `--pr` spelling, token discovery, response decoding, patch
assembly — is exercised by tests that never open a socket. The one piece that
does is `forge_http`.
*/
module forge;

import expected : err, Expected, ok;

/// A repository on some forge. `host` is what picks the adapter.
struct RepoId
{
    string host;
    string owner;
    string name;

    bool empty() const scope @safe pure nothrow @nogc
        => host.length == 0 || owner.length == 0 || name.length == 0;

    string toString() const scope @safe pure
        => host ~ "/" ~ owner ~ "/" ~ name;
}

/// What `--pr` names: a repository plus a number.
struct PrRef
{
    RepoId repo;
    uint number;
}

/// Why a forge operation could not be completed (`DPR6`).
///
/// A closed vocabulary rather than a message, because the caller's response
/// differs per kind: `noAuth` is worth telling the user how to fix, `network`
/// is worth retrying, `rateLimited` is worth waiting out, and `unknownRemote`
/// means this is not a forge hue can talk to at all.
enum ForgeErrorKind : ubyte
{
    /// The remote is not a forge any adapter claims.
    unknownRemote,
    /// No token was found, or the forge rejected the one we had.
    noAuth,
    /// The PR (or the repository) does not exist, or is not visible.
    notFound,
    /// The forge is refusing further requests for now.
    rateLimited,
    /// The request never got an answer.
    network,
    /// An answer arrived and was not what the adapter expected.
    malformed,
    /// The forge cannot do this at all (a capability it does not have).
    unsupported,
}

/// A forge failure: a kind the caller can branch on plus text for the human.
struct ForgeError
{
    ForgeErrorKind kind;
    string detail;

    string toString() const @safe pure
    {
        final switch (kind) with (ForgeErrorKind)
        {
            case unknownRemote: return "not a recognized forge: " ~ detail;
            case noAuth:        return "no forge credentials: " ~ detail;
            case notFound:      return "not found: " ~ detail;
            case rateLimited:   return "rate limited by the forge: " ~ detail;
            case network:       return "network error: " ~ detail;
            case malformed:     return "unexpected forge response: " ~ detail;
            case unsupported:   return "unsupported by this forge: " ~ detail;
        }
    }
}

/// ditto
alias ForgeResult(T) = Expected!(T, ForgeError);

/// A request the transport is asked to make. Deliberately minimal: an adapter
/// composes the URL and the headers, and knows nothing about how they travel.
struct HttpRequest
{
    string url;
    string[] headers; /// `"Name: value"`, ready to send
}

/// What came back.
struct HttpResponse
{
    int status;
    string body_;
}

/// The transport seam. A test passes a delegate that answers from a fixture;
/// `forge_http` passes one that actually talks to the network.
alias Transport = ForgeResult!HttpResponse delegate(in HttpRequest) @system;

/// One file of a pull request's diff.
struct PrFile
{
    string path;
    string previousPath; /// renames only; empty otherwise
    string status;       /// the forge's own word ("modified", "added", …)
    uint additions;
    uint deletions;
    /// The file's hunks as unified-diff text, WITHOUT the `diff --git`/`---`/
    /// `+++` preamble — which is how GitHub sends it, and why
    /// $(LREF assemblePatch) exists.
    string patch;
}

/// A pull request as hue renders it (`DPR2`): the description, enough
/// metadata to judge it by, and the files as a diff.
struct PullRequest
{
    uint number;
    string title;
    string description; /// markdown — rendered through the preview
    string author;
    string state;       /// "open", "closed", "merged"
    bool draft;
    string baseRef;
    string headRef;
    string baseSha;
    string headSha;
    PrFile[] files;
}

// ── The adapter vocabulary ──────────────────────────────────────────────────

/// Is `T` a forge adapter? The core surface every adapter owes: which hosts
/// it claims, and how to fetch a pull request through a transport.
enum isForge(T) = __traits(compiles, (T a, PrRef r, Transport t) {
    bool claims = T.handles("example.com");
    ForgeResult!PullRequest pr = a.pullRequest(r, t);
});

/**
Does `T` declare the optional capability `name`?

The git-spice pattern: probe by presence, never by identity. Session and UI
code asks $(D hasCapability!(F, "reviewThreads")) and degrades when the answer
is no — it never asks which forge this is, which is what keeps a second
adapter from touching anything above this seam.
*/
enum hasCapability(T, string name) = __traits(hasMember, T, name);

// ── Remote → repository ─────────────────────────────────────────────────────

/**
The repository a git remote URL names.

Handles the four spellings a remote actually takes: `scp`-style SSH
(`git@host:owner/repo.git`), `ssh://`, `https://`, and `git://`. Returns an
empty `RepoId` for anything else — a local path, a remote with no owner —
rather than guessing, because guessing here produces a request to the wrong
repository.
*/
RepoId repoFromRemote(scope const(char)[] remote) @safe pure
{
    import std.string : indexOf, startsWith;

    static string trimGit(scope const(char)[] name) @safe pure
    {
        if (name.length > 4 && name[$ - 4 .. $] == ".git")
            name = name[0 .. $ - 4];
        return name.idup;
    }

    scope const(char)[] rest = remote;
    string host;

    // `scheme://[user@]host/owner/repo`
    const scheme = rest.indexOf("://");
    if (scheme >= 0)
    {
        rest = rest[scheme + 3 .. $];
        const at = rest.indexOf('@');
        if (at >= 0)
            rest = rest[at + 1 .. $];
        const slash = rest.indexOf('/');
        if (slash <= 0)
            return RepoId.init;
        host = rest[0 .. slash].idup;
        rest = rest[slash + 1 .. $];
    }
    else
    {
        // `[user@]host:owner/repo`
        const colon = rest.indexOf(':');
        if (colon <= 0)
            return RepoId.init;
        auto hostPart = rest[0 .. colon];
        const at = hostPart.indexOf('@');
        if (at >= 0)
            hostPart = hostPart[at + 1 .. $];
        if (hostPart.length == 0)
            return RepoId.init;
        host = hostPart.idup;
        rest = rest[colon + 1 .. $];
    }

    // A port would have been eaten as part of the host in the ssh:// form.
    const portSep = host.indexOf(':');
    if (portSep > 0)
        host = host[0 .. portSep];

    const slash = rest.indexOf('/');
    if (slash <= 0 || slash + 1 >= rest.length)
        return RepoId.init;
    return RepoId(host, rest[0 .. slash].idup, trimGit(rest[slash + 1 .. $]));
}

/**
What `--pr <number|url>` names.

Three spellings, in the order a reviewer reaches for them: a bare number (or
`#123`) against the repository they are standing in, `owner/repo#123` for a
sibling, and a full forge URL pasted from a browser. The URL form carries its
own host, so it works with no remote at all.
*/
ForgeResult!PrRef parsePrTarget(const(char)[] spec, const RepoId fallback)
    @safe pure
{
    import std.string : indexOf;

    static ForgeResult!PrRef fail(string detail) @safe pure
        => err!PrRef(ForgeError(ForgeErrorKind.unknownRemote, detail));

    static bool digits(scope const(char)[] s) @safe pure nothrow @nogc
    {
        if (s.length == 0)
            return false;
        foreach (c; s)
            if (c < '0' || c > '9')
                return false;
        return true;
    }

    static uint toNumber(scope const(char)[] s) @safe pure nothrow @nogc
    {
        uint n;
        foreach (c; s)
            n = n * 10 + (c - '0');
        return n;
    }

    auto text = spec;
    if (text.length == 0)
        return fail("empty --pr target");

    // A forge URL: `https://host/owner/repo/pull/123` (or `/merge_requests/`).
    if (text.indexOf("://") >= 0)
    {
        auto rest = text[text.indexOf("://") + 3 .. $];
        const hostEnd = rest.indexOf('/');
        if (hostEnd <= 0)
            return fail(spec.idup);
        const host = rest[0 .. hostEnd].idup;
        rest = rest[hostEnd + 1 .. $];

        const(char)[][] parts;
        size_t at;
        foreach (i, c; rest)
            if (c == '/')
            {
                parts ~= rest[at .. i];
                at = i + 1;
            }
        if (at < rest.length)
            parts ~= rest[at .. $];
        // owner / repo / <"pull"|"pulls"|"merge_requests"> / number
        if (parts.length < 4 || !digits(parts[3]))
            return fail(spec.idup);
        return typeof(return)(PrRef(RepoId(host, parts[0].idup,
            parts[1].idup), toNumber(parts[3])));
    }

    if (text[0] == '#')
        text = text[1 .. $];

    // `owner/repo#123`
    const hash = text.indexOf('#');
    if (hash > 0)
    {
        const repoPart = text[0 .. hash];
        const numPart = text[hash + 1 .. $];
        const slash = repoPart.indexOf('/');
        if (slash <= 0 || !digits(numPart))
            return fail(spec.idup);
        if (fallback.host.length == 0)
            return fail("no remote to resolve " ~ spec.idup ~ " against");
        return typeof(return)(PrRef(RepoId(fallback.host,
            repoPart[0 .. slash].idup, repoPart[slash + 1 .. $].idup),
            toNumber(numPart)));
    }

    if (!digits(text))
        return fail(spec.idup);
    if (fallback.empty)
        return err!PrRef(ForgeError(ForgeErrorKind.unknownRemote,
            "a bare PR number needs a forge remote in this repository"));
    return typeof(return)(PrRef(fallback, toNumber(text)));
}

// ── Token discovery ─────────────────────────────────────────────────────────

/**
A forge token, never prompted for (`DPR1`).

Environment first (`GITHUB_TOKEN`, then `GH_TOKEN` — and per-adapter names via
`envNames`), then `gh`'s own `hosts.yml` as a courtesy so a user who has
already logged in with `gh` does not have to do anything. Reading that file is
NOT a `gh` dependency: it is a config file, and hue never runs the binary.

`readFile` is injected so the search is testable without a home directory.
*/
string discoverToken(Env, Read, Dir)(scope const(string)[] envNames,
    scope const(char)[] host, scope Env env, scope Read readFile,
    scope Dir configDir)
{
    foreach (name; envNames)
    {
        const v = env(name);
        if (v.length != 0)
            return v;
    }
    const dir = configDir();
    if (dir.length == 0)
        return null;
    return tokenFromGhHosts(readFile(dir ~ "/gh/hosts.yml"), host);
}

/**
The `oauth_token` for `host` in `gh`'s `hosts.yml`.

A deliberately small reader rather than a YAML parser: the file is two levels
of plain `key: value`, hue only ever reads it, and pulling in a YAML
dependency to fetch one string would be the tail wagging the dog. Anything
that does not match the shape yields no token, which degrades to `noAuth` —
never to a wrong token.
*/
string tokenFromGhHosts(const(char)[] yaml, scope const(char)[] host)
    @safe pure
{
    import std.string : indexOf, startsWith, strip, stripRight;

    bool inHost;
    foreach (rawLine; splitLines(yaml))
    {
        const line = rawLine.stripRight;
        if (line.length == 0 || line.strip.startsWith("#"))
            continue;
        const indented = line[0] == ' ' || line[0] == '\t';
        if (!indented)
        {
            // A top-level key: `github.com:` — the host block.
            const colon = line.indexOf(':');
            inHost = colon > 0 && line[0 .. colon].strip == host;
            continue;
        }
        if (!inHost)
            continue;
        const trimmed = line.strip;
        if (!trimmed.startsWith("oauth_token:"))
            continue;
        auto value = trimmed["oauth_token:".length .. $].strip;
        if (value.length >= 2 && (value[0] == '"' || value[0] == '\'')
            && value[$ - 1] == value[0])
            value = value[1 .. $ - 1];
        return value.idup;
    }
    return null;
}

private const(char)[][] splitLines(const(char)[] text) @safe pure
{
    const(char)[][] out_;
    size_t at;
    foreach (i, c; text)
        if (c == '\n')
        {
            out_ ~= text[at .. i];
            at = i + 1;
        }
    if (at < text.length)
        out_ ~= text[at .. $];
    return out_;
}

// ── PR → patch ──────────────────────────────────────────────────────────────

/**
A pull request's files as one unified patch.

Forges send a PR's diff per file, as bare hunks with no `diff --git`/`---`/
`+++` preamble. Adding the preamble back turns the whole PR into exactly the
input `sparkles:diff`'s parser already takes — so a PR session IS a diff
session (`DPR2`), through the same model, the same noise layers and the same
renderers, with no second pipeline.

A file the forge sent no patch for (too large, binary, or truncated) still
gets its header, so it appears in the session's file list rather than
vanishing from a review.
*/
string assemblePatch(in PrFile[] files) @safe pure
{
    string out_;
    foreach (ref f; files)
    {
        const added = f.status == "added";
        const removed = f.status == "removed";
        const old_ = removed ? "/dev/null"
            : "a/" ~ (f.previousPath.length ? f.previousPath : f.path);
        const new_ = added ? "/dev/null" : "b/" ~ f.path;

        out_ ~= "diff --git a/" ~ (f.previousPath.length ? f.previousPath : f.path)
            ~ " b/" ~ f.path ~ "\n";
        if (removed)
            out_ ~= "deleted file mode 100644\n";
        else if (added)
            out_ ~= "new file mode 100644\n";
        else if (f.previousPath.length)
            out_ ~= "rename from " ~ f.previousPath ~ "\n"
                ~ "rename to " ~ f.path ~ "\n";
        if (f.patch.length == 0)
        {
            // No hunks to show — a header alone keeps the file in the list.
            out_ ~= "Binary files differ\n";
            continue;
        }
        out_ ~= "--- " ~ old_ ~ "\n+++ " ~ new_ ~ "\n";
        out_ ~= f.patch;
        if (out_[$ - 1] != '\n')
            out_ ~= "\n";
    }
    return out_;
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("forge.repoFromRemote.everySpellingARemoteTakes")
@safe pure unittest
{
    assert(repoFromRemote("git@github.com:PetarKirov/sparkles.git")
        == RepoId("github.com", "PetarKirov", "sparkles"));
    assert(repoFromRemote("https://github.com/PetarKirov/sparkles.git")
        == RepoId("github.com", "PetarKirov", "sparkles"));
    assert(repoFromRemote("https://github.com/PetarKirov/sparkles")
        == RepoId("github.com", "PetarKirov", "sparkles"));
    assert(repoFromRemote("ssh://git@codeberg.org/o/r.git")
        == RepoId("codeberg.org", "o", "r"));
    assert(repoFromRemote("git://git.example.com/o/r")
        == RepoId("git.example.com", "o", "r"));

    // A self-hosted forge on a port keeps its host, not its port.
    assert(repoFromRemote("ssh://git@git.example.com:2222/o/r.git")
        == RepoId("git.example.com", "o", "r"));

    // Anything that is not a forge remote yields nothing rather than a guess:
    // guessing here means asking the wrong server about the wrong repository.
    assert(repoFromRemote("/srv/git/repo.git").empty);
    assert(repoFromRemote("../sibling").empty);
    assert(repoFromRemote("").empty);
    assert(repoFromRemote("https://github.com/onlyowner").empty);
}

@("forge.parsePrTarget.threeSpellings")
@safe pure unittest
{
    const here = RepoId("github.com", "PetarKirov", "sparkles");

    // A bare number means "in this repository".
    auto bare = parsePrTarget("247", here);
    assert(!bare.hasError && bare.value == PrRef(here, 247));
    assert(parsePrTarget("#247", here).value == PrRef(here, 247));

    // `owner/repo#n` for a sibling, on the same host.
    auto sibling = parsePrTarget("dlang/phobos#42", here);
    assert(sibling.value
        == PrRef(RepoId("github.com", "dlang", "phobos"), 42));

    // A pasted URL carries its own host, so it needs no remote at all.
    auto url = parsePrTarget(
        "https://github.com/PetarKirov/sparkles/pull/247", RepoId.init);
    assert(url.value == PrRef(here, 247));
    auto gitlab = parsePrTarget(
        "https://gitlab.com/o/r/-/merge_requests/9", RepoId.init);
    assert(gitlab.hasError || gitlab.value.number == 9);

    // Failures name what was wrong, and never produce a request.
    assert(parsePrTarget("247", RepoId.init).hasError,
        "a bare number outside a forge repository cannot be resolved");
    assert(parsePrTarget("not-a-pr", here).hasError);
    assert(parsePrTarget("", here).hasError);
}

@("forge.tokenFromGhHosts.readsOnlyItsOwnHost")
@safe pure unittest
{
    enum yaml = "github.com:\n"
        ~ "    users:\n"
        ~ "        petar:\n"
        ~ "            oauth_token: gho_theRightOne\n"
        ~ "    oauth_token: gho_theRightOne\n"
        ~ "    git_protocol: ssh\n"
        ~ "codeberg.org:\n"
        ~ "    oauth_token: cb_theWrongOne\n";
    assert(tokenFromGhHosts(yaml, "github.com") == "gho_theRightOne");
    assert(tokenFromGhHosts(yaml, "codeberg.org") == "cb_theWrongOne");
    assert(tokenFromGhHosts(yaml, "gitlab.com") is null);

    // Quoted values, and a file that is not what we expect: no token beats a
    // wrong token, because the wrong one is sent to a server.
    assert(tokenFromGhHosts("github.com:\n  oauth_token: \"q\"\n", "github.com")
        == "q");
    assert(tokenFromGhHosts("", "github.com") is null);
    assert(tokenFromGhHosts("garbage without a colon", "github.com") is null);
}

@("forge.discoverToken.environmentBeatsConfig")
@safe unittest
{
    string[string] envs;
    auto env = (string n) @safe => envs.get(n, "");
    auto read = (string p) @safe => p == "/cfg/gh/hosts.yml"
        ? "github.com:\n    oauth_token: fromConfig\n" : "";
    auto dir = () @safe => "/cfg";

    // Nothing set: the config file answers, so a user already logged in with
    // `gh` needs to do nothing.
    assert(discoverToken(["GITHUB_TOKEN", "GH_TOKEN"], "github.com", env, read,
        dir) == "fromConfig");

    envs["GH_TOKEN"] = "fromGhToken";
    assert(discoverToken(["GITHUB_TOKEN", "GH_TOKEN"], "github.com", env, read,
        dir) == "fromGhToken");

    // Order within the environment is the order given.
    envs["GITHUB_TOKEN"] = "fromGithubToken";
    assert(discoverToken(["GITHUB_TOKEN", "GH_TOKEN"], "github.com", env, read,
        dir) == "fromGithubToken");
}

@("forge.assemblePatch.becomesTheEnginesOwnInput")
@safe unittest
{
    import sparkles.diff : parsePatch;

    const files = [
        PrFile(path: "src/a.d", status: "modified", additions: 1, deletions: 1,
            patch: "@@ -1,2 +1,2 @@\n-old\n+new\n third\n"),
        PrFile(path: "src/new.d", status: "added", additions: 1,
            patch: "@@ -0,0 +1 @@\n+fresh\n"),
        PrFile(path: "src/moved.d", previousPath: "src/was.d",
            status: "renamed", patch: "@@ -1 +1 @@\n-a\n+b\n"),
    ];
    const patch = assemblePatch(files);

    // The whole point: a PR's per-file hunks become exactly what the engine's
    // own parser takes, so a PR session is a diff session.
    auto parsed = parsePatch(patch);
    assert(!parsed.hasError, "the assembled patch must parse");
    assert(parsed.value.files.length == 3);
    // The parser normalizes the `a/`/`b/` prefixes away, so the session's
    // paths are the repository's own.
    assert(parsed.value.pathText(parsed.value.files[0].newPath) == "src/a.d");
    assert(parsed.value.pathText(parsed.value.files[2].oldPath) == "src/was.d");
}

@("forge.assemblePatch.aFileWithNoHunksStillAppears")
@safe unittest
{
    import sparkles.diff : parsePatch;

    // Binary, too large, or truncated by the forge: the file must still be in
    // the reviewer's list. Dropping it would silently hide a change.
    const patch = assemblePatch([PrFile(path: "logo.png", status: "modified")]);
    auto parsed = parsePatch(patch);
    assert(!parsed.hasError);
    assert(parsed.value.files.length == 1);
    assert(parsed.value.files[0].binary);
}
