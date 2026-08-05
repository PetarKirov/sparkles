/++
Verify the VitePress sidebar in `docs/.vitepress/config.mts` is consistent
with the published markdown pages under `docs/`:

$(LIST
    $(ITEM pages → sidebar: every published page is linked from the sidebar)
    $(ITEM sidebar → pages: every sidebar link points at an existing published page)
)

Split out from `app.d` so the pure parsers and matchers can be unit-tested
(the main source file is excluded from the auto-generated test runner).
+/
module docs_sidebar;

import std.algorithm : canFind, sort;
import std.array : appender;
import std.regex : ctRegex, matchAll, matchFirst, regex;
import std.string : endsWith, indexOf, startsWith, strip;

/// Default config path relative to the repository root.
enum defaultVitePressConfig = "docs/.vitepress/config.mts";

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

/// Extract the text of a top-level array field like `sidebar: [` … `]` or
/// `srcExclude: [` … `]` from a VitePress config source string. Skips
/// bracket characters that appear inside single- or double-quoted strings
/// so nested `items: [` arrays do not confuse the depth counter.
/// Returns `null` when the field is missing or unbalanced.
@safe pure
string extractArrayField(string configText, string fieldName)
{
    const needle = fieldName ~ ":";
    const fieldIdx = configText.indexOf(needle);
    if (fieldIdx < 0)
        return null;

    size_t i = fieldIdx + needle.length;
    while (i < configText.length && (configText[i] == ' ' || configText[i] == '\t'
            || configText[i] == '\n' || configText[i] == '\r'))
        i++;

    if (i >= configText.length || configText[i] != '[')
        return null;

    const start = i;
    int depth = 0;
    bool inSingle = false;
    bool inDouble = false;
    bool escaped = false;

    for (; i < configText.length; i++)
    {
        const c = configText[i];

        if (escaped)
        {
            escaped = false;
            continue;
        }
        if (c == '\\' && (inSingle || inDouble))
        {
            escaped = true;
            continue;
        }
        if (c == '\'' && !inDouble)
        {
            inSingle = !inSingle;
            continue;
        }
        if (c == '"' && !inSingle)
        {
            inDouble = !inDouble;
            continue;
        }
        if (inSingle || inDouble)
            continue;

        if (c == '[')
            depth++;
        else if (c == ']')
        {
            depth--;
            if (depth == 0)
                return configText[start .. i + 1].idup;
        }
    }
    return null;
}

/// Collect every relative-path `link: '…'` / `link: "…"` from a sidebar
/// (or other) array section. External URLs (`http…`) are ignored.
///
/// Not `@pure`: `ctRegex` storage is mutable static data.
@safe
string[] extractSidebarLinks(string sidebarSection)
{
    static linkRe = ctRegex!(`link:\s*['"]([^'"]+)['"]`);
    auto result = appender!(string[]);
    foreach (m; sidebarSection.matchAll(linkRe))
    {
        const link = m.captures[1].idup;
        if (link.startsWith("http://") || link.startsWith("https://"))
            continue;
        if (link.startsWith("/"))
            result.put(link);
    }
    return result[];
}

/// Collect string-literal entries from a `srcExclude: [ … ]` section.
///
/// Not `@pure`: `ctRegex` storage is mutable static data.
@safe
string[] extractSrcExcludePatterns(string srcExcludeSection)
{
    static strRe = ctRegex!(`['"]([^'"]+)['"]`);
    auto result = appender!(string[]);
    foreach (m; srcExcludeSection.matchAll(strRe))
        result.put(m.captures[1].idup);
    return result[];
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

/// Parse a full VitePress config source and return unlinked docs pages
/// (pages → sidebar direction only). Prefer `checkDocsSidebarFromConfig`
/// for the bidirectional check used by the CLI.
@safe
string[] unlinkedDocsFromConfig(string configText, string[] mdFiles)
{
    return checkDocsSidebarFromConfig(configText, mdFiles).unlinkedPages;
}

/// Parse a full VitePress config source and run both directions of the
/// sidebar consistency check against the given docs markdown inventory.
@safe
DocsSidebarReport checkDocsSidebarFromConfig(string configText, string[] mdFiles)
{
    const sidebarSection = extractArrayField(configText, "sidebar");
    string[] links;
    if (sidebarSection !is null)
        links = extractSidebarLinks(sidebarSection);

    const srcExcludeSection = extractArrayField(configText, "srcExclude");
    string[] excludes;
    if (srcExcludeSection !is null)
        excludes = extractSrcExcludePatterns(srcExcludeSection);

    return DocsSidebarReport(
        unlinkedPages: findUnlinkedDocsPages(mdFiles, links, excludes),
        danglingLinks: findDanglingSidebarLinks(mdFiles, links, excludes),
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

@("docs_sidebar.extractArrayField.sidebar")
@safe
unittest
{
    // Indent with multiples of 4 so editorconfig-checker accepts the fixture.
    const cfg = q"EOS
export default {
    themeConfig: {
        nav: [{ text: 'Docs', link: '/overview' }],
        sidebar: [
            {
                text: 'Overview',
                items: [{ text: 'Package Overview', link: '/overview' }],
            },
            {
                text: 'Base',
                link: '/libs/base/',
                items: [
                    { text: 'API', link: '/libs/base/reference/api' },
                ],
            },
        ],
        socialLinks: [
            { icon: 'github', link: 'https://github.com/example/repo' },
        ],
    },
};
EOS";

    const section = extractArrayField(cfg, "sidebar");
    assert(section !is null);
    assert(section.canFind("/overview"));
    assert(section.canFind("/libs/base/"));
    // Must not include socialLinks (outside the sidebar array).
    assert(!section.canFind("github.com"));

    const links = extractSidebarLinks(section);
    assert(links == [
        "/overview",
        "/libs/base/",
        "/libs/base/reference/api",
    ]);
}

@("docs_sidebar.extractSrcExcludePatterns")
@safe
unittest
{
    const cfg = q"EOS
    srcExclude: [
        '**/research/parsing/grounding/**',
        "**/research/iroh/prompt.md",
    ],
EOS";
    const section = extractArrayField(cfg, "srcExclude");
    assert(section !is null);
    const patterns = extractSrcExcludePatterns(section);
    assert(patterns.length == 2);
    assert(patterns[0] == "**/research/parsing/grounding/**");
    assert(patterns[1] == "**/research/iroh/prompt.md");
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

@("docs_sidebar.checkDocsSidebarFromConfig.bidirectional")
@safe
unittest
{
    const cfg = q"EOS
export default defineConfig({
    srcExclude: ['**/secret/**'],
    themeConfig: {
        sidebar: [
            { text: 'Home-ish', link: '/overview' },
            { text: 'Ghost', link: '/does-not-exist' },
            { text: 'Hidden', link: '/secret/hidden' },
        ],
    },
});
EOS";
    const mdFiles = [
        "docs/index.md",
        "docs/overview.md",
        "docs/missing.md",
        "docs/secret/hidden.md",
    ];
    const report = checkDocsSidebarFromConfig(cfg, mdFiles.dup);
    assert(report.unlinkedPages == ["docs/missing.md"]);
    assert(report.danglingLinks == [
        "/does-not-exist",
        "/secret/hidden",
    ]);
    assert(!report.ok);
}

@("docs_sidebar.unlinkedDocsFromConfig")
@safe
unittest
{
    const cfg = q"EOS
export default defineConfig({
    srcExclude: ['**/secret/**'],
    themeConfig: {
        sidebar: [
            { text: 'Home-ish', link: '/overview' },
        ],
    },
});
EOS";
    const mdFiles = [
        "docs/index.md",
        "docs/overview.md",
        "docs/missing.md",
        "docs/secret/hidden.md",
    ];
    const missing = unlinkedDocsFromConfig(cfg, mdFiles.dup);
    assert(missing == ["docs/missing.md"]);
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
