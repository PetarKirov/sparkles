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

@safe:

/// `owner`/`name` of a GitHub repository, parsed from a remote URL.
struct RepoSlug
{
    string owner;
    string name;
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
