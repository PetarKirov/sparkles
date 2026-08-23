/++
The explorer sidebar as $(B one shared asset) instead of markup repeated on
every page ([`DOC12`](../../../../../docs/specs/docs/site.md)).

The per-page renderer this replaces emitted the whole file tree into each
document: ~3,200 nodes at ~133 bytes, in every one of 2,300 pages — 70% of the
site's bytes, re-downloaded per navigation and impossible for a CDN to reuse.
Here the tree is data ($(LREF explorerJson)) written once under a
content-addressed name, and $(LREF explorerScript) — the client module that
renders it — is a second such asset. Both are immutable-cacheable: a reader
pays for the tree on the first page and for nothing on the next.

JSON, deliberately, rather than the same object baked into the script: the two
change on different schedules (the tree on every content edit, the renderer
almost never), and only separate files let a content-addressed cache keep the
half that did not change.

The sidebar is the one part of a page that needs JavaScript. Content, header,
breadcrumbs, and the directory indexes stay server-rendered, so the no-JS
reader — and `file://`, where `fetch` may not read a sibling — loses the
explorer and nothing else ($(LREF explorerPlaceholder) carries the note).
+/
module sparkles.docs.explorer;

import std.array : appender, Appender;

import sparkles.docs.sidebar : SidebarItem;
import sparkles.docs.site_tree : DirNode, SiteTree;
import sparkles.wired.policy : WireOptional, WireSkip;

/// The site's client layer, verbatim (`views/site.js`): the explorer renderer
/// plus the soft navigation that keeps it alive across a click (`DOC13`). A
/// string import so the JavaScript stays a JavaScript file — linted,
/// formatted and diffed as one — rather than a D string literal.
enum siteScript = import("site.js");

/++
The tree the client reads, as $(B types) — `sparkles:wired` encodes them
(`DOC12`). Short keys: this file ships to every reader.

`@WireOptional(WireSkip.whenDefault)` is what keeps it small: an empty `dirs`,
`files` or `nav` is omitted rather than written as `[]`, which for a tree of
2,300 nodes is most of the leaves.
+/
struct ExplorerFile
{
    string label; /// the page's name, as shown
    string href;  /// its file name inside the directory
}

/// One directory: its repo-relative path (`""` at the root) and what is in it.
struct ExplorerNode
{
    string path;
    @WireOptional(WireSkip.whenDefault) ExplorerNode[] dirs;
    @WireOptional(WireSkip.whenDefault) ExplorerFile[] files;
}

/// The whole asset: the prefix a docs-nav page route resolves against, the
/// tree, and the augmented sidebar tree (`DSC7`) the client renders inline as
/// the `docs/` node's children.
struct ExplorerData
{
    string base;
    ExplorerNode root;
    @WireOptional(WireSkip.whenDefault) const(SidebarItem)[] nav;
}

/// $(LREF ExplorerData) for a site tree — the shape, without the encoding.
ExplorerData explorerData(const SiteTree tree, const SidebarItem[] nav,
    scope const(char)[] base) @safe pure
{
    size_t[string] at;
    foreach (idx, ref const n; tree.nodes)
        at[n.relPath] = idx;

    // Explicit attributes: a self-recursive nested function gets no inference.
    static ExplorerNode buildAt(const SiteTree tree, const size_t[string] at,
        const DirNode node) @safe pure
    {
        ExplorerNode out_;
        out_.path = node.relPath;
        foreach (ref const d; node.dirs)
        {
            const bare = d.label[0 .. $ - 1]; // "name/" → "name"
            const childRel = node.relPath.length
                ? node.relPath ~ "/" ~ bare : bare;
            if (auto idx = childRel in at)
                out_.dirs ~= buildAt(tree, at, tree.nodes[*idx]);
        }
        foreach (ref const f; node.files)
            out_.files ~= ExplorerFile(label: f.label, href: f.href);
        return out_;
    }

    auto root = "" in at;
    return ExplorerData(base: base.idup,
        root: root ? buildAt(tree, at, tree.nodes[*root]) : ExplorerNode.init,
        nav: nav);
}

/++
$(LREF explorerData) as the minified JSON written to
`assets/tree-<hash>.json`.

Not `@safe pure`: `sparkles:wired`'s encoder is neither, and one shared
serializer is worth more than the attributes on a function that runs once per
site build.
+/
string explorerJson(const SiteTree tree, const SidebarItem[] nav,
    scope const(char)[] base)
{
    import sparkles.wired.json : writeJSON;

    auto w = appender!string;
    const r = writeJSON(explorerData(tree, nav, base), w);
    if (r.hasError)
        throw new Exception("explorer tree does not encode: " ~ r.error.reason);
    w ~= "\n";
    return w[];
}

/++
The empty aside the client module fills, carrying everything it needs: where
the tree is (`data-tree`), how to reach the site root from $(I this) page
(`data-root`, so hrefs stay relative and `file://` keeps working), and which
page is current (`data-current`).

Without JavaScript the aside stays empty; CSS collapses it to nothing, so the
page reads as one without a sidebar rather than one with a hole in it.
+/
string explorerPlaceholder(scope const(char)[] treeHref, scope const(char)[] root,
    scope const(char)[] currentOut) @safe pure
{
    import sparkles.docs.options : escapeInto;

    auto w = appender!string;
    w ~= "<aside class=\"site-sidebar site-explorer\" id=\"site-explorer\" data-tree=\"";
    escapeInto(w, treeHref);
    w ~= "\" data-root=\"";
    escapeInto(w, root);
    w ~= "\" data-current=\"";
    escapeInto(w, currentOut);
    w ~= "\"></aside>";
    return w[];
}

/// `depth` levels of `../`, i.e. the site root as seen from a page at that
/// depth — `data-root` for $(LREF explorerPlaceholder).
string rootPrefix(size_t depth) @safe pure nothrow
{
    auto w = appender!string;
    foreach (_; 0 .. depth)
        w ~= "../";
    return w[];
}

// ---------------------------------------------------------------------------

/// The JSON carries the tree the client renders: nested directories, the
/// files in each, and the docs nav under its own key.
@("docs.explorer.explorerJson.shape")
@system
unittest
{
    import sparkles.docs.site_tree : buildSiteTree;
    import sparkles.docs.source_set : SourceEntry;

    const entries = [
        SourceEntry(name: "top.d", relPath: "top.d", outPath: "top.d.html"),
        SourceEntry(name: "x.d", relPath: "libs/a/x.d", outPath: "libs/a/x.d.html"),
    ];
    const json = explorerJson(buildSiteTree(entries),
        [SidebarItem(text: "Overview", link: "/overview")], "/src/");

    // Empty `dirs`/`files`/`nav` members are omitted, not written as `[]`
    // (`WireSkip.whenDefault`) — most of a 2,300-node tree is leaves.
    assert(json ==
        `{"base":"/src/","root":{"path":"","dirs":[{"path":"libs","dirs":`
        ~ `[{"path":"libs/a","files":[{"label":"x.d","href":"x.d.html"}]}]}],`
        ~ `"files":[{"label":"top.d","href":"top.d.html"}]},`
        ~ `"nav":[{"text":"Overview","link":"/overview"}]}` ~ "\n", json);
}

/// The placeholder names the asset, the way back to the root, and the page —
/// the three things the client cannot infer from a page at unknown depth.
@("docs.explorer.explorerPlaceholder.carriesItsContext")
@safe pure
unittest
{
    assert(explorerPlaceholder("../../assets/tree-abc.json", "../../",
        "libs/a/x.d.html")
        == `<aside class="site-sidebar site-explorer" id="site-explorer"`
        ~ ` data-tree="../../assets/tree-abc.json" data-root="../../"`
        ~ ` data-current="libs/a/x.d.html"></aside>`);
    assert(rootPrefix(0) == "" && rootPrefix(3) == "../../../");
}
