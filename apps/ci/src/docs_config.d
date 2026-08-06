/++
The machine-readable docs-site data files, and their D schema.

`docs/.vitepress/sidebar.json` (the sidebar tree) and
`docs/.vitepress/docs-config.json` (today: `srcExclude`) are the single source
of truth for both the site and the repo tooling:

$(LIST
    $(ITEM `docs/.vitepress/config.mts` imports them and passes them straight
        to `themeConfig.sidebar` / `srcExclude`)
    $(ITEM `ci --check-docs-sidebar` (see `docs_sidebar`) checks the sidebar
        against the published pages in both directions)
    $(ITEM `ci --audit-fences` (see `fence_audit`) uses the same `srcExclude`
        to decide which files the site builds)
)

Before this module the tooling scraped the `config.mts` text with a
bracket-depth counter and a `link: '…'` regex — brittle against a bracket in a
comment, a template literal, or a renamed field. Reading JSON removes the
guessing: the data is data, and a malformed file is a hard error rather than a
silently empty link set.
+/
module docs_config;

import expected : Expected;
import sparkles.wired.json : JsonError, readJSONFile;
import sparkles.wired.policy : WireOptional;

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
    @WireOptional() string link;

    /// Whether a group renders collapsed. Absent for leaf entries.
    @WireOptional() bool collapsed;

    /// Child entries of a group; empty for a leaf.
    @WireOptional() SidebarItem[] items;
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

/// Loads the sidebar tree from `<repoRoot>/docs/.vitepress/sidebar.json`.
LoadResult!(SidebarItem[]) loadSidebar(string repoRoot)
{
    import std.path : buildPath;

    return readJSONFile!(SidebarItem[])(repoRoot.buildPath(sidebarDataPath));
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

// ── unittests ──────────────────────────────────────────────────────────────

// `@system`: wired's native decode walk infers `@system` for a recursive
// aggregate (the arena view is pointer-based).
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
