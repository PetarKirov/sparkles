/++
Verify the VitePress sidebar — `docs/.vitepress/sidebar.json`, the data file
`config.mts` imports (see `docs_config`) — is consistent with the published
markdown pages under `docs/`:

$(LIST
    $(ITEM pages → sidebar: every published page is linked from the sidebar)
    $(ITEM sidebar → pages: every sidebar link points at an existing published page)
)

Split out from `app.d` so the pure matchers can be unit-tested (the main source
file is excluded from the auto-generated test runner).
+/
module docs_sidebar;

import docs_config : SidebarItem, sidebarLinks;

import std.algorithm : canFind, sort;
import std.array : appender;
import std.regex : matchFirst, regex;
import std.string : endsWith, startsWith, strip;

/// Route key for the VitePress home page (`docs/index.md`).
/// It is reachable as `/` even when not listed in the sidebar.
enum homePageRoute = "";

/// Combined result of a bidirectional sidebar check.
struct DocsSidebarReport
{
    /// Repo-relative `docs/**/*.md` paths with no matching sidebar link.
    string[] unlinkedPages;

    /// Raw sidebar `link` values that do not resolve to a published page.
    string[] danglingLinks;

    /// True when both directions are clean.
    @safe pure nothrow @nogc
    bool ok() const => unlinkedPages.length == 0 && danglingLinks.length == 0;
}

/// Normalize a VitePress sidebar `link` (e.g. `/libs/base/`, `/overview`)
/// or a repo-relative docs path (e.g. `docs/libs/base/index.md`) to a
/// comparable route key without leading/trailing slashes or a trailing
/// `/index` segment.
@safe pure
string normalizeDocsRoute(string path)
{
    auto s = path.strip;
    if (s.startsWith("docs/"))
        s = s["docs/".length .. $];
    if (s.startsWith("/"))
        s = s[1 .. $];
    if (s.endsWith(".md"))
        s = s[0 .. $ - ".md".length];
    if (s.endsWith("/index"))
        s = s[0 .. $ - "/index".length];
    else if (s == "index")
        s = "";
    while (s.endsWith("/"))
        s = s[0 .. $ - 1];
    return s.idup;
}

/// Convert a VitePress/micromatch-style glob (`**`, `*`, `?`) to a D regex
/// pattern that matches a path relative to the docs root.
@safe pure
string globToRegexPattern(string pattern)
{
    auto r = appender!string;
    r.put('^');
    size_t i = 0;
    while (i < pattern.length)
    {
        if (i + 1 < pattern.length && pattern[i] == '*' && pattern[i + 1] == '*')
        {
            if (i + 2 < pattern.length && pattern[i + 2] == '/')
            {
                // **/ — zero or more path segments plus a trailing slash
                r.put("(?:.*/)?");
                i += 3;
            }
            else
            {
                r.put(".*");
                i += 2;
            }
        }
        else if (pattern[i] == '*')
        {
            r.put("[^/]*");
            i++;
        }
        else if (pattern[i] == '?')
        {
            r.put("[^/]");
            i++;
        }
        else
        {
            // Escape regex metacharacters.
            const c = pattern[i];
            if ("\\.^$+()[]{}|".canFind(c))
                r.put('\\');
            r.put(c);
            i++;
        }
    }
    r.put('$');
    return r[];
}

/// True when `path` (relative to the docs root, e.g. `research/foo/bar.md`)
/// matches any of the VitePress `srcExclude` globs.
@safe
bool isSrcExcluded(string path, string[] patterns)
{
    foreach (pattern; patterns)
    {
        auto re = regex(globToRegexPattern(pattern));
        if (!matchFirst(path, re).empty)
            return true;
    }
    return false;
}

/// Map a repo-relative docs markdown path to its normalized route key.
/// Returns `null` when the path is outside `docs/` or is not a `.md` file.
@safe pure
string docsFileToRoute(string repoPath)
{
    if (!repoPath.startsWith("docs/") || !repoPath.endsWith(".md"))
        return null;
    // Assets under public/ are not VitePress pages.
    if (repoPath.startsWith("docs/public/"))
        return null;
    return normalizeDocsRoute(repoPath);
}

/// Build the set of normalized routes that correspond to published pages
/// (tracked markdown under `docs/`, minus `srcExclude` and non-page paths).
@safe
bool[string] publishedRouteSet(string[] mdFiles, string[] srcExcludePatterns)
{
    bool[string] routes;
    foreach (file; mdFiles)
    {
        const route = docsFileToRoute(file);
        if (route is null)
            continue;

        // Path relative to docs/ for srcExclude matching.
        const rel = file["docs/".length .. $];
        if (isSrcExcluded(rel, srcExcludePatterns))
            continue;

        routes[route] = true;
    }
    return routes;
}

/// Compute the sorted list of docs markdown paths that are not linked from
/// the sidebar (and not covered by `srcExclude` or the implicit home page).
///
/// `mdFiles` — repo-relative paths (`docs/…/*.md`).
/// `sidebarLinks` — raw sidebar `link` values (`/foo`, `/bar/`).
/// `srcExcludePatterns` — globs relative to the docs root.
@safe
string[] findUnlinkedDocsPages(
    string[] mdFiles,
    string[] sidebarLinks,
    string[] srcExcludePatterns,
)
{
    bool[string] linked;
    linked[homePageRoute] = true;
    foreach (link; sidebarLinks)
        linked[normalizeDocsRoute(link)] = true;

    auto missing = appender!(string[]);
    foreach (file; mdFiles)
    {
        const route = docsFileToRoute(file);
        if (route is null)
            continue;

        // Path relative to docs/ for srcExclude matching.
        const rel = file["docs/".length .. $];
        if (isSrcExcluded(rel, srcExcludePatterns))
            continue;

        if (route !in linked)
            missing.put(file.idup);
    }

    auto result = missing[];
    result.sort;
    return result;
}

/// Compute the sorted list of sidebar links that do not resolve to a
/// published page. Deduplicates by normalized route, keeping the first raw
/// link form seen. Links that only match an `srcExclude`-d path are treated
/// as dangling (the page is not published).
///
/// `mdFiles` — repo-relative paths (`docs/…/*.md`).
/// `sidebarLinks` — raw sidebar `link` values (`/foo`, `/bar/`).
/// `srcExcludePatterns` — globs relative to the docs root.
@safe
string[] findDanglingSidebarLinks(
    string[] mdFiles,
    string[] sidebarLinks,
    string[] srcExcludePatterns,
)
{
    auto existing = publishedRouteSet(mdFiles, srcExcludePatterns);

    bool[string] seen;
    auto dangling = appender!(string[]);
    foreach (link; sidebarLinks)
    {
        const route = normalizeDocsRoute(link);
        if (route in seen)
            continue;
        seen[route] = true;

        if (route !in existing)
            dangling.put(link.idup);
    }

    auto result = dangling[];
    result.sort;
    return result;
}

/// Run both directions of the sidebar consistency check for a decoded
/// `sidebar.json` tree, the site's `srcExclude` globs, and the docs markdown
/// inventory (repo-relative `docs/…/*.md` paths).
@safe
DocsSidebarReport checkDocsSidebar(
    in SidebarItem[] sidebar,
    string[] srcExclude,
    string[] mdFiles,
)
{
    auto links = sidebarLinks(sidebar);
    return DocsSidebarReport(
        unlinkedPages: findUnlinkedDocsPages(mdFiles, links, srcExclude),
        danglingLinks: findDanglingSidebarLinks(mdFiles, links, srcExclude),
    );
}

// ── unittests ──────────────────────────────────────────────────────────────

@("docs_sidebar.normalizeDocsRoute")
@safe pure
unittest
{
    assert(normalizeDocsRoute("/libs/base/") == "libs/base");
    assert(normalizeDocsRoute("/libs/base") == "libs/base");
    assert(normalizeDocsRoute("/libs/base/index") == "libs/base");
    assert(normalizeDocsRoute("docs/libs/base/index.md") == "libs/base");
    assert(normalizeDocsRoute("docs/libs/base.md") == "libs/base");
    assert(normalizeDocsRoute("docs/index.md") == "");
    assert(normalizeDocsRoute("/overview") == "overview");
    assert(normalizeDocsRoute("docs/overview.md") == "overview");
}

// `@system`: wired's decode of the recursive `SidebarItem` tree infers
// `@system` (see docs_config); the link collection itself is `@safe pure`.
@("docs_sidebar.sidebarJsonLinks")
@system
unittest
{
    import sparkles.wired.json : fromJSON;

    // The shape `sidebar.json` actually has: nested groups, group headings
    // that carry a link of their own, and leaf entries.
    const json = `[
        {
            "text": "Overview",
            "collapsed": false,
            "items": [{ "text": "Package Overview", "link": "/overview" }]
        },
        {
            "text": "Base",
            "link": "/libs/base/",
            "collapsed": true,
            "items": [{ "text": "API", "link": "/libs/base/reference/api" }]
        }
    ]`;

    auto decoded = fromJSON!(SidebarItem[])(json);
    assert(!decoded.hasError, decoded.error.reason);
    assert(sidebarLinks(decoded.value) == [
        "/overview",
        "/libs/base/",
        "/libs/base/reference/api",
    ]);
}

@("docs_sidebar.globToRegexPattern / isSrcExcluded")
@safe
unittest
{
    assert(isSrcExcluded(
        "research/parsing/grounding/foo.md",
        ["**/research/parsing/grounding/**"],
    ));
    assert(isSrcExcluded(
        "research/iroh/prompt.md",
        ["**/research/iroh/prompt.md"],
    ));
    assert(!isSrcExcluded(
        "research/iroh/index.md",
        ["**/research/iroh/prompt.md"],
    ));
    assert(!isSrcExcluded(
        "research/parsing/concepts.md",
        ["**/research/parsing/grounding/**"],
    ));
    assert(isSrcExcluded(
        "research/application-packaging/PLAN.md",
        ["**/research/application-packaging/PLAN.md"],
    ));
}

@("docs_sidebar.findUnlinkedDocsPages")
@safe
unittest
{
    const mdFiles = [
        "docs/index.md",
        "docs/overview.md",
        "docs/libs/base/index.md",
        "docs/libs/base/orphan.md",
        "docs/research/parsing/grounding/claim.md",
        "docs/public/readme.md",
    ];
    const links = ["/overview", "/libs/base/"];
    const excludes = ["**/research/parsing/grounding/**"];

    const missing = findUnlinkedDocsPages(mdFiles.dup, links.dup, excludes.dup);
    assert(missing == ["docs/libs/base/orphan.md"]);
}

@("docs_sidebar.findDanglingSidebarLinks")
@safe
unittest
{
    const mdFiles = [
        "docs/index.md",
        "docs/overview.md",
        "docs/libs/base/index.md",
        "docs/research/parsing/grounding/claim.md",
    ];
    // /ghost is missing entirely; /research/... is srcExcluded so also dangling;
    // /overview and /libs/base/ resolve; duplicate raw forms of the same route
    // should only appear once.
    const links = [
        "/overview",
        "/libs/base/",
        "/ghost",
        "/libs/base",
        "/research/parsing/grounding/claim",
    ];
    const excludes = ["**/research/parsing/grounding/**"];

    const dangling = findDanglingSidebarLinks(mdFiles.dup, links.dup, excludes.dup);
    assert(dangling == [
        "/ghost",
        "/research/parsing/grounding/claim",
    ]);
}

@("docs_sidebar.checkDocsSidebar.bidirectional")
@safe
unittest
{
    const sidebar = [
        SidebarItem(text: "Home-ish", link: "/overview"),
        SidebarItem(text: "Ghost", link: "/does-not-exist"),
        SidebarItem(text: "Hidden", link: "/secret/hidden"),
        SidebarItem(text: "Upstream", link: "https://example.com/"),
    ];
    const mdFiles = [
        "docs/index.md",
        "docs/overview.md",
        "docs/missing.md",
        "docs/secret/hidden.md",
    ];
    const report = checkDocsSidebar(sidebar, ["**/secret/**"], mdFiles.dup);
    assert(report.unlinkedPages == ["docs/missing.md"]);
    assert(report.danglingLinks == [
        "/does-not-exist",
        "/secret/hidden",
    ]);
    assert(!report.ok);
}

@("docs_sidebar.checkDocsSidebar.clean")
@safe
unittest
{
    // A tree that links every published page — the state the CLI requires.
    const sidebar = [
        SidebarItem(text: "Overview", items: [
            SidebarItem(text: "Package Overview", link: "/overview"),
        ]),
        SidebarItem(text: "Base", link: "/libs/base/"),
    ];
    const mdFiles = [
        "docs/index.md",
        "docs/overview.md",
        "docs/libs/base/index.md",
        "docs/secret/hidden.md",
        "docs/public/asset.md",
    ];
    const report = checkDocsSidebar(sidebar, ["**/secret/**"], mdFiles.dup);
    assert(report.unlinkedPages.length == 0);
    assert(report.danglingLinks.length == 0);
    assert(report.ok);
}

@("docs_sidebar.DocsSidebarReport.ok")
@safe pure nothrow
unittest
{
    DocsSidebarReport clean;
    assert(clean.ok);
    assert(!DocsSidebarReport(unlinkedPages: ["docs/x.md"]).ok);
    assert(!DocsSidebarReport(danglingLinks: ["/x"]).ok);
}
