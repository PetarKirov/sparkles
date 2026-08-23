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
import sparkles.docs.site : writeJsonString;
import sparkles.docs.site_tree : DirNode, SiteTree;

/// The client renderer, verbatim (`views/explorer.js`). A string import so the
/// JavaScript stays a JavaScript file — linted, formatted and diffed as one —
/// rather than a D string literal.
enum explorerScript = import("explorer.js");

/++
The site tree plus the docs nav as the JSON $(LREF explorerScript) reads.

Shape (short keys — this file ships to every reader):
$(LIST
    $(ITEM `base` — the prefix a docs-nav page route resolves against)
    $(ITEM `root` — `{ path, name, dirs: [node…], files: [{label, href}…] }`,
        `path` repo-relative (`""` at the root), `href` the page's file name
        inside its directory)
    $(ITEM `nav` — the augmented sidebar tree (`DSC7`), rendered inline as the
        `docs/` node's children)
)
+/
string explorerJson(in SiteTree tree, scope const SidebarItem[] nav,
    scope const(char)[] base) @safe pure
{
    size_t[string] at;
    foreach (idx, ref const n; tree.nodes)
        at[n.relPath] = idx;

    auto w = appender!string;
    w ~= "{\"base\":";
    writeJsonString(w, base);
    w ~= ",\"root\":";
    if (auto root = "" in at)
        writeNode(w, tree, at, tree.nodes[*root]);
    else
        w ~= "{\"path\":\"\"}";
    if (nav.length)
    {
        w ~= ",\"nav\":";
        writeNav(w, nav);
    }
    w ~= "}\n";
    return w[];
}

private void writeNode(ref Appender!string w, in SiteTree tree,
    in size_t[string] at, in DirNode node) @safe pure
{
    import std.algorithm.searching : startsWith;

    w ~= "{\"path\":";
    writeJsonString(w, node.relPath);
    if (node.dirs.length)
    {
        w ~= ",\"dirs\":[";
        bool first = true;
        foreach (ref const d; node.dirs)
        {
            const bare = d.label[0 .. $ - 1]; // "name/" → "name"
            const childRel = node.relPath.length
                ? node.relPath ~ "/" ~ bare : bare;
            auto idx = childRel in at;
            if (idx is null)
                continue;
            w ~= first ? "" : ",";
            first = false;
            writeNode(w, tree, at, tree.nodes[*idx]);
        }
        w ~= "]";
    }
    if (node.files.length)
    {
        w ~= ",\"files\":[";
        foreach (i, ref const f; node.files)
        {
            w ~= i ? ",{\"label\":" : "{\"label\":";
            writeJsonString(w, f.label);
            w ~= ",\"href\":";
            writeJsonString(w, f.href);
            w ~= "}";
        }
        w ~= "]";
    }
    w ~= "}";
}

private void writeNav(ref Appender!string w, scope const SidebarItem[] items) @safe pure
{
    w ~= "[";
    foreach (i, ref const it; items)
    {
        w ~= i ? ",{\"text\":" : "{\"text\":";
        writeJsonString(w, it.text);
        if (it.link.length)
        {
            w ~= ",\"link\":";
            writeJsonString(w, it.link);
        }
        if (it.collapsed)
            w ~= ",\"collapsed\":true";
        if (it.target.length)
        {
            w ~= ",\"target\":";
            writeJsonString(w, it.target);
        }
        if (it.rel.length)
        {
            w ~= ",\"rel\":";
            writeJsonString(w, it.rel);
        }
        if (it.items.length)
        {
            w ~= ",\"items\":";
            writeNav(w, it.items);
        }
        w ~= "}";
    }
    w ~= "]";
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
@safe pure
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
