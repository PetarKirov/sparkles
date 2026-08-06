/**
The gallery's **output tree** ([`gallery.md` `GAL12`](../../../docs/specs/hue/gallery.md)):
a document set's paths turned into a directory structure, and one directory's
`index.html`.

A flat gallery writes `<out>/<name>.html` and a single `index.html`. That does not
survive a source tree — `foo/app.d` and `bar/app.d` are one page — so a recursive
set ([`SRC9`](../../../docs/specs/hue/feature-requirements.md)) mirrors instead:
`<out>/<rel-path>.html` per document plus an `index.html` per directory. This
module is the shape of that tree, and it is $(B pure): $(LREF buildSiteTree) is a
transformation of a `SourceEntry[]`, $(LREF directoryIndex) is a string builder
over one node. Writing them is [`gallery.writeGallery`](./gallery.d)'s job.

The flat layout is the depth-0 case, not a separate path:
`gallery.galleryIndex` is $(LREF directoryIndex) over the root node of a set whose
entries all sit at the root, and it emits the same bytes it always did.
*/
module site_tree;

import std.array : appender;

import gallery : escapeInto, SiteOptions;
import source_set : SourceEntry;

/// One row of a directory index: a link, its text, and its summary.
struct IndexRow
{
    /// href relative to the directory's own `index.html` — a page's file name,
    /// or a child directory's `<name>/index.html`
    string href;

    /// the link text: a document's base name, or a child directory's `<name>/`
    string label;

    /// the document's summary (`GAL8`); empty for a directory row
    string summary;
}

/**
One directory of the output tree: the pages it holds and the directories below
it, each already resolved to a row an index can render.
*/
struct DirNode
{
    /// the directory's path relative to the gallery root — `""` for the root
    /// itself, so `""` sorts first
    string relPath;

    /// immediate child directories, sorted by name
    IndexRow[] dirs;

    /// the directory's own pages, in set order
    IndexRow[] files;

    /// How deep this directory sits below the gallery root (`0` for the root) —
    /// the number of `../` steps back up to it.
    size_t depth() const scope @safe pure nothrow @nogc
    {
        if (relPath.length == 0)
            return 0;
        size_t n = 1;
        foreach (char c; relPath)
            if (c == '/')
                ++n;
        return n;
    }
}

/**
The output tree of `entries`: one node per directory that holds a page $(B or) is
an ancestor of one — an intermediate directory with no documents of its own still
gets a node (and therefore an index), so the chain of parent links is unbroken.

Nodes come out sorted by $(D relPath) with the root first; a node's `files` follow
the set's order (already sorted by source path) and its `dirs` are sorted by name.
*/
SiteTree buildSiteTree(scope const SourceEntry[] entries) @safe pure
{
    import std.algorithm.sorting : sort;

    SiteTree tree;
    foreach (ref const e; entries)
    {
        // An entry assembled by hand (a caller of `gallery.galleryIndex`, a test)
        // may carry only a display name; `collectSources` always fills `outPath`.
        const outPath = e.outPath.length ? e.outPath : e.name ~ ".html";
        const cut = lastSlash(outPath);
        const dir = cut == -1 ? "" : outPath[0 .. cast(size_t) cut];
        const file = cut == -1 ? outPath : outPath[cast(size_t) cut + 1 .. $];
        tree.nodeFor(dir).files ~= IndexRow(href: file, label: e.name, summary: e.summary);
    }

    // Every non-root node is a row in its parent (which `nodeFor` has already
    // created, so the loop needs no second pass).
    foreach (i; 0 .. tree.nodes.length)
    {
        const rel = tree.nodes[i].relPath;
        if (rel.length == 0)
            continue;
        const cut = lastSlash(rel);
        const parent = cut == -1 ? "" : rel[0 .. cast(size_t) cut];
        const name = cut == -1 ? rel : rel[cast(size_t) cut + 1 .. $];
        tree.nodeFor(parent).dirs ~= IndexRow(href: name ~ "/index.html", label: name ~ "/");
    }

    foreach (ref node; tree.nodes)
        node.dirs.sort!((a, b) => a.label < b.label);
    tree.nodes.sort!((a, b) => a.relPath < b.relPath);
    return tree;
}

/// The directories of one gallery, root first (see $(LREF buildSiteTree)).
struct SiteTree
{
    DirNode[] nodes;

    /**
    The node for `relPath`, creating it — and every missing ancestor — on first
    reference. Returns by reference: the caller appends rows to it.
    */
    private ref DirNode nodeFor(scope const(char)[] relPath) @safe pure
    {
        foreach (i, ref n; nodes)
            if (n.relPath == relPath)
                return nodes[i];

        // Ancestors first, so a deep path materializes the whole chain.
        if (relPath.length)
        {
            const cut = lastSlash(relPath);
            if (cut > 0)
                nodeFor(relPath[0 .. cast(size_t) cut]);
            else
                nodeFor("");
        }
        nodes ~= DirNode(relPath: relPath.idup);
        return nodes[$ - 1];
    }
}

/// The index of `dir`'s position in `path`, or `-1` — `lastIndexOf('/')` without
/// pulling `std.string` in for one character.
private ptrdiff_t lastSlash(scope const(char)[] path) @safe pure nothrow @nogc
{
    for (ptrdiff_t i = cast(ptrdiff_t) path.length - 1; i >= 0; --i)
        if (path[cast(size_t) i] == '/')
            return i;
    return -1;
}

/**
One directory's `index.html` (`GAL2`/`GAL12`): its child directories, then its
pages with their summaries. A node with neither says so explicitly rather than
rendering an empty list (`GAL9`).

The root node of a flat set renders exactly what the flat gallery index always
did — the mirrored layout adds a heading that names the directory, a link back up
to its parent, and the child-directory rows, all of which the root of a
one-directory set has none of.
*/
string directoryIndex(in DirNode dir, in SiteOptions opt = SiteOptions.init) @safe pure
{
    const nested = dir.relPath.length != 0;

    auto w = appender!string;
    w ~= "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n";
    w ~= "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n";
    w ~= "<title>";
    if (nested)
    {
        escapeInto(w, opt.titlePrefix);
        w ~= " · ";
        escapeInto(w, dir.relPath);
        w ~= "/";
    }
    else
        escapeInto(w, opt.indexTitle.length ? opt.indexTitle : opt.heading);
    w ~= "</title>\n<style>\n";
    w ~= indexCss;
    w ~= "</style></head><body>\n<h1>";
    if (nested)
    {
        escapeInto(w, dir.relPath);
        w ~= "/";
    }
    else
        escapeInto(w, opt.heading);
    w ~= "</h1>\n<p>";
    if (nested)
        writeParentLinks(w, dir.depth);
    else
        w ~= opt.blurb; // trusted, caller-supplied markup
    w ~= "</p>\n";

    if (dir.dirs.length == 0 && dir.files.length == 0)
    {
        w ~= "<p><em>No documents to show.</em></p>\n</body></html>\n";
        return w[];
    }

    w ~= "<ul>\n";
    foreach (rows; [dir.dirs, dir.files])
        foreach (r; rows)
        {
            w ~= "  <li><a href=\"";
            escapeInto(w, r.href);
            w ~= "\">";
            escapeInto(w, r.label);
            w ~= "</a>";
            if (r.summary.length)
            {
                w ~= "<code>";
                escapeInto(w, r.summary);
                w ~= "</code>";
            }
            w ~= "</li>\n";
        }
    w ~= "</ul>\n</body></html>\n";
    return w[];
}

/// The way back up out of a nested directory: its parent, and — from deep enough
/// for the parent alone not to help — the gallery root. Both indices are always
/// written, so neither link can dangle.
private void writeParentLinks(Writer)(ref Writer w, size_t depth) @safe pure
{
    w ~= "<a href=\"../index.html\">↑ parent</a>";
    if (depth > 1)
    {
        w ~= " · <a href=\"";
        foreach (_; 0 .. depth)
            w ~= "../";
        w ~= "index.html\">root</a>";
    }
}

/// The index chrome. Shared by every directory index (and, through
/// `gallery.galleryIndex`, the flat one) so a set looks the same at every depth.
private enum indexCss =
    "  body { margin: 0 auto; max-width: 48em; padding: 2em 1.5em;\n" ~
    "         background: #11111b; color: #cdd6f4; font: 15px/1.6 system-ui, sans-serif; }\n" ~
    "  h1 { font-size: 1.4em; } p { color: #a6adc8; }\n" ~
    "  ul { list-style: none; padding: 0; }\n" ~
    "  li { padding: 0.5em 0; border-bottom: 1px solid #1e1e2e; }\n" ~
    "  a { color: #89b4fa; text-decoration: none; font-weight: 600; }\n" ~
    "  a:hover { text-decoration: underline; }\n" ~
    "  code { color: #a6adc8; font-size: 0.9em; margin-left: 0.6em; }\n";

// ---------------------------------------------------------------------------

@("site_tree.buildSiteTree.mirrorsDirectoriesAndFillsGaps")
@safe pure
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    const entries = [
        SourceEntry(name: "app.d", summary: "d · 1 line",
            relPath: "a/app.d", outPath: "a/app.d.html"),
        SourceEntry(name: "app.d", summary: "d · 2 lines",
            relPath: "b/deep/app.d", outPath: "b/deep/app.d.html"),
        SourceEntry(name: "top.d", summary: "d · 3 lines",
            relPath: "top.d", outPath: "top.d.html"),
    ];
    const tree = buildSiteTree(entries);

    // Root first, then every directory — including `b`, which holds no document
    // of its own but must still have an index for `b/deep`'s parent link.
    assert(tree.nodes.map!(n => n.relPath).array == ["", "a", "b", "b/deep"]);

    assert(tree.nodes[0].dirs.map!(r => r.href).array == ["a/index.html", "b/index.html"]);
    assert(tree.nodes[0].files.map!(r => r.href).array == ["top.d.html"]);
    // A page's href is relative to its own directory's index.
    assert(tree.nodes[1].files == [IndexRow("app.d.html", "app.d", "d · 1 line")]);
    assert(tree.nodes[2].files.length == 0);
    assert(tree.nodes[2].dirs == [IndexRow("deep/index.html", "deep/", "")]);
    assert(tree.nodes[3].depth == 2 && tree.nodes[0].depth == 0);
}

/// A flat set is the depth-0 case: one node, no child directories, every page a
/// sibling of the index.
@("site_tree.buildSiteTree.flatSetIsOneRootNode")
@safe pure
unittest
{
    const tree = buildSiteTree([
        SourceEntry(name: "01-hover", relPath: "01-hover", outPath: "01-hover.html"),
    ]);
    assert(tree.nodes.length == 1 && tree.nodes[0].relPath == "");
    assert(tree.nodes[0].dirs.length == 0);
    assert(tree.nodes[0].files == [IndexRow("01-hover.html", "01-hover", "")]);
}

@("site_tree.directoryIndex.nestedIndexLinksUpAndDown")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const node = DirNode(relPath: "libs/base",
        dirs: [IndexRow("text/index.html", "text/")],
        files: [IndexRow("app.d.html", "app.d", "d · 1 line")]);
    const idx = directoryIndex(node);

    assert(idx.canFind("<title>hue · libs/base/</title>"), idx);
    assert(idx.canFind("<h1>libs/base/</h1>"), idx);
    // Up to the parent index, and (depth 2) to the root one.
    assert(idx.canFind("<a href=\"../index.html\">↑ parent</a>"), idx);
    assert(idx.canFind("<a href=\"../../index.html\">root</a>"), idx);
    // Directories before files; a directory row carries no summary cell.
    const dirAt = idx.canFind("<a href=\"text/index.html\">text/</a></li>");
    assert(dirAt, idx);
    assert(idx.canFind("<a href=\"app.d.html\">app.d</a><code>d · 1 line</code>"), idx);
}

/// The root index of a nested gallery links its subdirectories but has no
/// parent to climb to — and an empty node still says so (`GAL9`).
@("site_tree.directoryIndex.rootHasNoParentLink")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const idx = directoryIndex(DirNode(dirs: [IndexRow("a/index.html", "a/")]));
    assert(!idx.canFind("parent"), idx);
    assert(idx.canFind("<a href=\"a/index.html\">a/</a>"), idx);

    assert(directoryIndex(DirNode.init).canFind("No documents to show"));
}
