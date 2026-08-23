/++
The machine-readable docs-site data files, and their D schema.

`docs/.vitepress/sidebar.json` (the sidebar tree) and
`docs/.vitepress/docs-config.json` (today: `srcExclude`) are the single source
of truth for both the site and the repo tooling:

$(LIST
    $(ITEM `docs/.vitepress/config.mts` imports them and passes them straight
        to `themeConfig.sidebar` / `srcExclude`)
    $(ITEM `ci --check-docs-sidebar` (`apps/ci/src/docs_sidebar.d`) checks the sidebar
        against the published pages in both directions)
    $(ITEM `ci --audit-fences` (`apps/ci/src/fence_audit.d`) uses the same `srcExclude`
        to decide which files the site builds)
)

Before this module the tooling scraped the `config.mts` text with a
bracket-depth counter and a `link: '…'` regex — brittle against a bracket in a
comment, a template literal, or a renamed field. Reading JSON removes the
guessing: the data is data, and a malformed file is a hard error rather than a
silently empty link set.
+/
module sparkles.docs.sidebar;

import std.algorithm.searching : canFind;
import std.array : Appender, appender;
import std.regex : matchFirst, regex;

import expected : Expected;
import sparkles.wired.json : JsonError, readJSONFile;
import sparkles.wired.policy : WireOptional, WireSkip;

import sparkles.docs.options : ChromePalette, escapeInto;

/// Path of the sidebar data file, relative to the repository root.
enum sidebarDataPath = "docs/.vitepress/sidebar.json";

/// Path of the remaining shared docs config, relative to the repository root.
enum docsConfigPath = "docs/.vitepress/docs-config.json";

/++
One node of the VitePress sidebar tree, as it appears in `sidebar.json`.

Mirrors the subset of VitePress's `DefaultTheme.SidebarItem` the site actually
uses (verified against the fully-resolved config: the tree contains only
`text`, `link`, `collapsed`, and `items`). Unknown keys decode as no-ops, so a
future VitePress field does not break the tools.
+/
struct SidebarItem
{
    /// Label shown in the sidebar. Always present.
    string text;

    /// Route the entry links to (`/overview`, `/libs/base/`), or empty for a
    /// group heading that is not itself a page.
    @WireOptional(WireSkip.whenDefault) string link;

    /// Whether a group renders collapsed. Absent for leaf entries.
    @WireOptional(WireSkip.whenDefault) bool collapsed;

    /// Child entries of a group; empty for a leaf.
    @WireOptional(WireSkip.whenDefault) SidebarItem[] items;

    /// Anchor `target` for the rendered link (VitePress's `DefaultTheme`
    /// honors it). The listing entries set `_blank`: a `/src/…` route is a
    /// static page, and a plain sidebar link would be intercepted by the SPA
    /// router — which has no such route — and 404, where a real navigation
    /// serves the file (`DSC7`).
    @WireOptional(WireSkip.whenDefault) string target;

    /// Anchor `rel` for the rendered link.
    @WireOptional(WireSkip.whenDefault) string rel;
}

/// The contents of `docs-config.json`.
struct DocsConfig
{
    /// VitePress `srcExclude` globs (relative to the docs root, `**`-anchored):
    /// pages the site does not build.
    string[] srcExclude;
}

/// Result of loading one of the data files: the value, or the `JsonError`
/// describing the I/O, parse, or decode failure (wired never throws).
alias LoadResult(T) = Expected!(T, JsonError);

/// Loads a sidebar tree from an explicit `sidebar.json` path (the shape of
/// `docs/.vitepress/sidebar.json`, wherever it lives — `hue gallery --sidebar`
/// takes the file, not a repository).
LoadResult!(SidebarItem[]) loadSidebarFile(string path)
    => readJSONFile!(SidebarItem[])(path);

/// Loads the sidebar tree from `<repoRoot>/docs/.vitepress/sidebar.json`.
LoadResult!(SidebarItem[]) loadSidebar(string repoRoot)
{
    import std.path : buildPath;

    return loadSidebarFile(repoRoot.buildPath(sidebarDataPath));
}

/// Loads `<repoRoot>/docs/.vitepress/docs-config.json`.
LoadResult!DocsConfig loadDocsConfig(string repoRoot)
{
    import std.path : buildPath;

    return readJSONFile!DocsConfig(repoRoot.buildPath(docsConfigPath));
}

/++
Collects every in-site `link` from a sidebar tree, depth-first in document
order. External links (`http://`, `https://`) and entries without a link are
skipped, as are links that are not site-absolute — VitePress sidebar links are
always rooted at `/`.
+/
@safe pure
string[] sidebarLinks(in SidebarItem[] items)
{
    import std.array : appender;

    auto result = appender!(string[]);
    void walk(in SidebarItem[] nodes)
    {
        foreach (const ref node; nodes)
        {
            if (node.link.length && node.link[0] == '/')
                result.put(node.link);
            walk(node.items);
        }
    }

    walk(items);
    return result[];
}

// ── the srcExclude visibility rule ─────────────────────────────────────────

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

// ── the sidebar on generated pages (DOC8) ─────────────────────────────────

/++
Renders a sidebar tree as the `<aside class="site-sidebar">` a generated page
splices in ([`DOC8`](../../../../../docs/specs/docs/site.md)): groups as
pure-CSS `<details>` (open unless the data says `collapsed`), leaves as links.

`siteBase` is what the site-absolute routes resolve against — the docs site's
base URL (`https://…`, no trailing slash) or empty to leave them root-absolute
(right when the listings are deployed under the same origin, useless from
`file://`). An external (`http…`) link is passed through untouched.

Returns markup only; the caller carries it into pages via
`GalleryOptions.sidebarHtml`, which is a $(I string) so the options vocabulary
stays plain data at the bottom of the package's import graph.
+/
string sidebarNav(in SidebarItem[] items, scope const(char)[] siteBase = null) @safe pure
{
    auto w = appender!string;
    w ~= "<aside class=\"site-sidebar\"><nav aria-label=\"Docs navigation\">\n";
    w ~= sidebarItemsHtml(items, siteBase);
    w ~= "</nav></aside>";
    return w[];
}

/// The tree's items alone — no `<aside>`/`<nav>` wrapper — for embedding
/// inside another nav: the explorer sidebar nests this under its `docs/`
/// node (`explorer.explorerScript`, `DOC11`/`DOC12`).
string sidebarItemsHtml(in SidebarItem[] items, scope const(char)[] siteBase = null) @safe pure
{
    auto w = appender!string;
    writeSidebarItems(w, items, siteBase);
    return w[];
}

private void writeSidebarItems(ref Appender!string w, in SidebarItem[] items,
    scope const(char)[] base) @safe pure
{
    foreach (const ref it; items)
    {
        if (it.items.length)
        {
            w ~= "<details class=\"sb-group\"";
            if (!it.collapsed)
                w ~= " open";
            w ~= "><summary>";
            if (it.link.length)
                writeSidebarLink(w, it.text, it.link, base);
            else
                escapeInto(w, it.text);
            w ~= "</summary><div class=\"sb-items\">\n";
            writeSidebarItems(w, it.items, base);
            w ~= "</div></details>\n";
        }
        else if (it.link.length)
        {
            writeSidebarLink(w, it.text, it.link, base);
            w ~= "\n";
        }
        else
        {
            w ~= "<span class=\"sb-text\">";
            escapeInto(w, it.text);
            w ~= "</span>\n";
        }
    }
}

private void writeSidebarLink(ref Appender!string w, scope const(char)[] text,
    scope const(char)[] link, scope const(char)[] base) @safe pure
{
    import std.algorithm.searching : startsWith;

    w ~= "<a class=\"sb-link\" href=\"";
    if (!link.startsWith("http://", "https://") && base.length)
        escapeInto(w, base);
    escapeInto(w, link);
    w ~= "\">";
    escapeInto(w, text);
    w ~= "</a>";
}

/++
The sidebar's chrome, from the same $(D ChromePalette) the page uses — plus the
`html.dark` half when `dark` is set, exactly like the rest of the shell.

Only the aside's own rules: the `.shell`/`.content` flex row that places it
belongs to the page (`page_shell.pageShell` / `site_tree.directoryIndex`),
which each own their layout.
+/
string sidebarCss(in ChromePalette c, in ChromePalette dark = ChromePalette.init) @safe pure
{
    import std.conv : text;

    auto w = appender!string;
    // An explorer aside arrives empty and is filled by its client module
    // (`DOC12`). Without JavaScript it stays empty, and a 16.5em blank column
    // reads as a broken sidebar — so an empty one takes no space at all.
    w ~= "  .site-sidebar:empty { display: none; }\n";
    w ~= "  .site-sidebar { flex: none; width: 16.5em; overflow-y: auto;\n";
    w ~= text("                  padding: 0.9em 1.1em 1.5em; box-sizing: border-box;\n");
    w ~= text("                  background: ", c.surface, "; border-right: 1px solid ",
        c.border, "; font-size: 0.92em; }\n");
    w ~= text("  .site-sidebar a.sb-link { color: ", c.text,
        "; text-decoration: none; display: block; padding: 0.12em 0; }\n");
    w ~= text("  .site-sidebar a.sb-link:hover { color: ", c.link, "; }\n");
    w ~= "  .site-sidebar .sb-group { margin: 0 0 0.4em; }\n";
    w ~= "  .site-sidebar summary { cursor: pointer; font-weight: 600; padding: 0.25em 0; }\n";
    w ~= text("  .site-sidebar .sb-items { padding-left: 0.9em; margin-left: 0.15em;\n");
    w ~= text("                            border-left: 1px solid ", c.border, "; }\n");
    w ~= text("  .site-sidebar .sb-text { color: ", c.muted, "; }\n");
    // Explorer extras (`DOC11`): a directory's name is a link inside its
    // `<summary>` (the marker toggles, the name navigates), and the current
    // page is highlighted.
    w ~= "  .site-sidebar summary a.sb-link { display: inline; padding: 0; }\n";
    w ~= text("  .site-sidebar a.sb-link.active { color: ", c.link,
        "; font-weight: 600; }\n");
    if (dark.background.length)
    {
        w ~= text("  html.dark .site-sidebar { background: ", dark.surface,
            "; border-right-color: ", dark.border, "; }\n");
        w ~= text("  html.dark .site-sidebar a.sb-link { color: ", dark.text, "; }\n");
        w ~= text("  html.dark .site-sidebar a.sb-link:hover { color: ", dark.link, "; }\n");
        w ~= text("  html.dark .site-sidebar .sb-items { border-left-color: ",
            dark.border, "; }\n");
        w ~= text("  html.dark .site-sidebar .sb-text { color: ", dark.muted, "; }\n");
        w ~= text("  html.dark .site-sidebar a.sb-link.active { color: ", dark.link, "; }\n");
    }
    return w[];
}

// ── unittests ──────────────────────────────────────────────────────────────

// `@system`: wired's native decode walk infers `@system` for a recursive
// aggregate (the arena view is pointer-based).
@("sidebar.sidebarNav.groupsLinksBaseAndEscaping")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const items = [
        SidebarItem(text: "Overview", link: "/overview"),
        SidebarItem(text: "Specs <1>", collapsed: true, items: [
            SidebarItem(text: "Hue", link: "/specs/hue/"),
        ]),
        SidebarItem(text: "Libraries", link: "/libs/", items: [
            SidebarItem(text: "External", link: "https://example.org/x"),
        ]),
    ];
    const html = sidebarNav(items, "https://docs.example");

    // Site-absolute routes resolve against the base; external links pass through.
    assert(html.canFind(`href="https://docs.example/overview"`), html);
    assert(html.canFind(`href="https://docs.example/specs/hue/"`), html);
    assert(html.canFind(`href="https://example.org/x"`), html);
    assert(!html.canFind("https://docs.examplehttps://"), html);

    // A collapsed group renders closed, an expanded one open, and a group with
    // its own route links from the summary.
    assert(html.canFind(`<details class="sb-group"><summary>Specs &lt;1&gt;</summary>`), html);
    assert(html.canFind(`<details class="sb-group" open><summary><a class="sb-link" href="https://docs.example/libs/"`), html);

    // No base: routes stay root-absolute.
    assert(sidebarNav(items).canFind(`href="/overview"`));
}

@("docs_config.SidebarItem.decode.nested")
@system
unittest
{
    import sparkles.wired.json : fromJSON;

    // Shape of the real file: groups carry `collapsed` + `items`, leaves carry
    // `link`; an unknown key must not fail the decode.
    const text = `[
        {
            "text": "Overview",
            "collapsed": false,
            "items": [{ "text": "Package Overview", "link": "/overview" }]
        },
        {
            "text": "Base",
            "collapsed": true,
            "docFooterText": "ignored",
            "items": [
                {
                    "text": "Reference",
                    "collapsed": true,
                    "items": [{ "text": "API", "link": "/libs/base/reference/api" }]
                }
            ]
        }
    ]`;

    auto res = fromJSON!(SidebarItem[])(text);
    assert(!res.hasError, res.error.reason);
    const tree = res.value;

    assert(tree.length == 2);
    assert(tree[0].text == "Overview" && !tree[0].collapsed);
    assert(tree[0].items.length == 1 && tree[0].items[0].link == "/overview");
    assert(tree[1].collapsed);
    assert(tree[1].items[0].items[0].link == "/libs/base/reference/api");
    // A group heading has no link of its own.
    assert(tree[1].link.length == 0);
}

@("docs_config.sidebarLinks.documentOrder")
@safe
unittest
{
    const tree = [
        SidebarItem(text: "Overview", items: [
            SidebarItem(text: "Package Overview", link: "/overview"),
        ]),
        SidebarItem(text: "Base", link: "/libs/base/", items: [
            SidebarItem(text: "API", link: "/libs/base/reference/api"),
            SidebarItem(text: "Upstream", link: "https://example.com/base"),
            SidebarItem(text: "Nested", items: [
                SidebarItem(text: "Deep", link: "/libs/base/how-to/deep"),
            ]),
        ]),
        SidebarItem(text: "Heading only"),
    ];

    assert(sidebarLinks(tree) == [
        "/overview",
        "/libs/base/",
        "/libs/base/reference/api",
        "/libs/base/how-to/deep",
    ]);
}

@("docs_config.DocsConfig.decode")
@safe
unittest
{
    import sparkles.wired.json : fromJSON;

    auto res = fromJSON!DocsConfig(
        `{ "srcExclude": ["**/research/**/grounding/**", "**/x/prompt.md"] }`);
    assert(!res.hasError, res.error.reason);
    assert(res.value.srcExclude == [
        "**/research/**/grounding/**",
        "**/x/prompt.md",
    ]);
}

/// ditto
@("docs_config.loadSidebar.missingFileIsAnError")
@system
unittest
{
    auto res = loadSidebar("/nonexistent-repo-root");
    assert(res.hasError);
}

@("sidebar.globToRegexPattern / isSrcExcluded")
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
