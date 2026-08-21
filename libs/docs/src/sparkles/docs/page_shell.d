/**
hue's HTML sink, part two — the multi-document **gallery** around the content
fragments ([`HTM6`–`HTM8`](../../../../../docs/specs/hue/feature-requirements.md),
[`gallery.md` `GAL2`–`GAL7`](../../../../../docs/specs/hue/gallery.md)).

Everything needed to present a fragment as a page — a header with prev/next
nav, breadcrumbs, a line-number gutter, a single scroll container, selection
domains, the appearance toggle — used to live in a node script that shelled out
to hue once per file. That page shell is the library's own output, so it lives
here, in D, where it is unit-testable.

Structure: $(B pure string builders + one I/O seam). $(LREF pageShell) and
$(LREF galleryIndex) build the page text; only $(LREF writeGallery) touches
disk.
*/
module sparkles.docs.page_shell;

import std.array : appender, Appender;
import std.conv : text;

import sparkles.syntax;

import sparkles.docs.fragment : withLineNumbers;
import sparkles.docs.options;
import sparkles.docs.source_set : SourceEntry, SourceSet;

// ── the page shell (GAL3, GAL6, GAL7) ──────────────────────────────────────

/**
Wraps a content `fragment` in the full preview shell (`GAL3`/`GAL6`): a header
(prev · name · summary · index · next), a full-height single scroll container, a
theme-matched background, the physical-line gutter (`GAL4`), and the selection
domains (`GAL7`).

`prev`/`next` are hrefs $(B relative to this page) — `next.html`, or
`../other/app.d.html` in a mirrored gallery ($(LREF pageHref) computes them). An
empty one renders its link disabled (rather than omitted) so the header does not
reflow between pages. The index link is the literal `index.html`, which resolves
to whichever directory index sits beside the page, at any depth.
*/
string pageShell(scope const(char)[] name, scope const(char)[] summary, string fragment,
    scope const(char)[] prev, scope const(char)[] next,
    in GalleryOptions opt = GalleryOptions.init,
    scope const(char)[] relPath = null) @safe pure
{
    import sparkles.docs.breadcrumbs : breadcrumbCss, breadcrumbScript, breadcrumbsFor,
        renderBreadcrumbs;

    const crumbs = relPath.length
        ? breadcrumbsFor(relPath, opt.repoUrl, opt.repoPrefix) : null;

    int gutter;
    const body_ = withLineNumbers(fragment, gutter);
    const c = opt.chrome;

    auto w = appender!string;
    w ~= "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n";
    w ~= "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n";
    w ~= "<title>";
    escapeInto(w, opt.titlePrefix);
    w ~= " · ";
    escapeInto(w, name);
    w ~= "</title>\n";
    if (opt.hasDarkChrome)
        w ~= noFlashScript;
    if (opt.stylesheetHref.length)
    {
        w ~= "<link rel=\"stylesheet\" href=\"";
        escapeInto(w, opt.stylesheetHref);
        w ~= "\">\n";
    }
    w ~= "<style>\n";
    w ~= "  html, body { height: 100%; }\n";
    w ~= text("  body { margin: 0; background: ", c.background, "; color: ", c.text, ";\n");
    w ~= "         font: 14px/1.5 system-ui, sans-serif;\n";
    w ~= "         display: flex; flex-direction: column; }\n";
    w ~= "  header { flex: none; display: flex; gap: 0.9em; align-items: baseline;\n";
    w ~= "           flex-wrap: wrap; padding: 0.7em 1em;\n";
    w ~= text("           background: ", c.surface, "; border-bottom: 1px solid ",
        c.border, "; }\n");
    w ~= text("  header b { font-size: 1.05em; } header .kinds { color: ", c.muted, "; }\n");
    w ~= text("  header .spacer { flex: 1; } header a { color: ", c.link,
        "; text-decoration: none; }\n");
    w ~= "  header a:hover { text-decoration: underline; }\n";
    w ~= text("  header .disabled { color: ", c.faint, "; }\n");
    // Gated with the button itself — a single-theme page has no toggle, so
    // shipping its rules on every page would be dead CSS.
    if (opt.hasDarkChrome)
    {
        w ~= text("  #hue-appearance { background: none; border: 1px solid ", c.border,
            "; color: ", c.link, ";\n");
        w ~= "                    border-radius: 4px; cursor: pointer; font-size: 1em;\n";
        w ~= "                    line-height: 1; padding: 0.15em 0.45em; }\n";
    }
    // The single scroll container: the code pane fills the remaining height, so
    // only ONE scrollbar ever appears (no nested body + pre scrollbars).
    w ~= text("  main { flex: 1; min-height: 0; overflow: auto; background: ",
        c.background, "; }\n");
    if (opt.hasDarkChrome)
    {
        const d = opt.darkChrome;
        w ~= text("  html.dark body, html.dark main { background: ", d.background,
            "; }\n");
        w ~= text("  html.dark body { color: ", d.text, "; }\n");
        w ~= text("  html.dark header { background: ", d.surface,
            "; border-bottom-color: ", d.border, "; }\n");
        w ~= text("  html.dark header .kinds { color: ", d.muted, "; }\n");
        w ~= text("  html.dark header a { color: ", d.link, "; }\n");
        w ~= text("  html.dark header .disabled { color: ", d.faint, "; }\n");
        w ~= text("  html.dark .ln::before { color: ", d.faint, "; }\n");
        w ~= text("  html.dark #hue-appearance { border-color: ", d.border,
            "; color: ", d.link, "; }\n");
    }
    w ~= "  main pre.syn-root { margin: 0; padding: 0.6em 1ch; min-height: 100%;\n";
    w ~= "                      box-sizing: border-box; }\n";
    // Line-number gutter: a left pad on <code> holds the numbers; each physical
    // line's number is generated content (never selected/copied). Below-line
    // annotations aren't `.ln`, so they carry no number and don't advance it.
    w ~= "  main pre.syn-root > code { display: block; counter-reset: lineno;\n";
    w ~= text("                             padding-left: ", gutter, "ch; }\n");
    // `.ln` is INLINE — the physical `\n` after each span (kept by relayoutGutter)
    // draws the line breaks under `white-space: pre` and gives blank lines their
    // height, and a copied selection keeps every line.
    w ~= "  .ln { position: relative; counter-increment: lineno; }\n";
    w ~= "  .ln::before { content: counter(lineno); position: absolute;\n";
    w ~= text("                left: -", gutter, "ch; width: ", gutter - 1, "ch; text-align: right;\n");
    w ~= text("                color: ", c.faint,
        "; -webkit-user-select: none; user-select: none; }\n");
    // Selection domains (VSCode-like). The shipped twoslash.css sets the below-line
    // annotations `user-select: none` (code copies cleanly for every consumer). The
    // gallery goes further: a drag is confined to whichever domain it STARTS in —
    // the code, or one annotation. Override the shipped `none` back to selectable
    // so a drag can begin inside an annotation…
    w ~= "  main .twoslash :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n";
    w ~= "    -webkit-user-select: text; user-select: text; }\n";
    // …started in code → annotations drop out of the selection;
    w ~= "  body.sel-code :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n";
    w ~= "    -webkit-user-select: none; user-select: none; }\n";
    // …started in an annotation → only that one stays selectable (contained).
    w ~= "  body.sel-anno main pre.syn-root > code { -webkit-user-select: none; user-select: none; }\n";
    w ~= "  body.sel-anno :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n";
    w ~= "    -webkit-user-select: none; user-select: none; }\n";
    w ~= "  body.sel-anno .sel-active, body.sel-anno .sel-active * {\n";
    w ~= "    -webkit-user-select: text; user-select: text; }\n";
    if (crumbs.length)
    {
        w ~= "  .crumbs { flex: none; padding: 0.55em 1em 0; }\n";
        w ~= breadcrumbCss(c, opt.hasDarkChrome ? opt.darkChrome : ChromePalette.init);
    }
    w ~= "</style></head><body>\n<header>";
    navLink(w, prev, "← prev", "prev");
    w ~= "<b>";
    escapeInto(w, name);
    w ~= "</b><span class=\"kinds\">";
    escapeInto(w, summary);
    w ~= "</span><span class=\"spacer\"></span><a href=\"index.html\">all</a>";
    navLink(w, next, "next →", "next");
    if (opt.hasDarkChrome)
        w ~= themeToggleButton;
    w ~= "</header>\n";
    if (crumbs.length)
    {
        w ~= "<div class=\"crumbs\">";
        renderBreadcrumbs(w, crumbs);
        w ~= "</div>\n";
    }
    w ~= "<main>";
    w ~= body_;
    w ~= "</main>\n";
    // Confine each drag to the domain it started in: mark the annotation the
    // mousedown landed in (if any) and flag the body so the CSS above restricts the
    // other domain. Runs before the drag extends, so the restriction applies to the
    // selection this mousedown begins.
    w ~= "<script>\n";
    w ~= "const A = '.twoslash-meta-line,.twoslash-completion-list,.twoslash-tag-line';\n";
    w ~= "addEventListener('mousedown', e => {\n";
    w ~= "  document.querySelectorAll('.sel-active').forEach(el => el.classList.remove('sel-active'));\n";
    w ~= "  const a = e.target.closest(A);\n";
    w ~= "  if (a) a.classList.add('sel-active');\n";
    w ~= "  document.body.classList.toggle('sel-anno', !!a);\n";
    w ~= "  document.body.classList.toggle('sel-code', !a);\n";
    w ~= "});\n";
    if (opt.hasDarkChrome)
        w ~= themeToggleScript;
    if (crumbs.length)
        w ~= breadcrumbScript;
    w ~= "</script>\n</body></html>\n";
    return w[];
}

/**
The appearance key, and why it is VitePress's.

A generated listing sits *inside* the docs site: a reader follows a link from a
VitePress page to a hue page and back. Two independent preferences would mean
the theme flipping at that boundary, twice per round trip. Writing the key
VitePress already owns means one preference for the whole site, and it survives
the SPA boundary in both directions.

`auto` is VitePress's third state (follow the OS), and the value it stores when
the reader has never chosen — so an absent key and a literal `"auto"` have to
behave identically.
*/
private enum appearanceKey = "vitepress-theme-appearance";

/// Applies the stored appearance before first paint.
///
/// In `<head>`, deliberately: run after the body renders and the page paints
/// light, then repaints dark — the flash the docs site does not have. Wrapped
/// in `try` because a `file://` page with cookies blocked throws on
/// `localStorage` access, and an exception here would abort the rest of the
/// document.
private enum noFlashScript =
    "<script>
" ~
    "try {
" ~
    "  const p = localStorage.getItem('" ~ appearanceKey ~ "');
" ~
    "  const dark = p === 'dark' || ((!p || p === 'auto') &&
" ~
    "    matchMedia('(prefers-color-scheme: dark)').matches);
" ~
    "  document.documentElement.classList.toggle('dark', dark);
" ~
    "} catch (e) {}
" ~
    "</script>
";

/// The header control. `aria-pressed` rather than an icon swap alone, so the
/// state is announced rather than only drawn.
private enum themeToggleButton =
    `<button id="hue-appearance" type="button" aria-pressed="false"` ~
    ` title="Toggle dark mode">◐</button>`;

/// Flips the class and stores the choice under `appearanceKey`.
private enum themeToggleScript =
    "const T = document.getElementById('hue-appearance');
" ~
    "const sync = () => T.setAttribute('aria-pressed',
" ~
    "  String(document.documentElement.classList.contains('dark')));
" ~
    "sync();
" ~
    "T.addEventListener('click', () => {
" ~
    "  const dark = document.documentElement.classList.toggle('dark');
" ~
    "  try { localStorage.setItem('" ~ appearanceKey ~
    "', dark ? 'dark' : 'light'); } catch (e) {}
" ~
    "  sync();
" ~
    "});
";

/// A header nav link, or a disabled span when there is no such neighbour.
private void navLink(ref Appender!string w, scope const(char)[] href,
    string label, string cls) @safe pure
{
    if (href.length)
    {
        w ~= text("<a class=\"", cls, "\" href=\"");
        escapeInto(w, href);
        w ~= text("\">", label, "</a>");
    }
    else
        w ~= text("<span class=\"", cls, " disabled\">", label, "</span>");
}

/**
The gallery's root `index.html` (`GAL2`) for a $(B flat) set: every entry as a
link plus its summary. An empty set renders an explicit "no documents" note
rather than an empty list (`GAL9`).

A convenience over [`site_tree`](./site_tree.d)'s
`directoryIndex(buildSiteTree(entries).nodes[0])` — the flat layout is the
depth-0 case of the mirrored one (`GAL12`), not a second renderer — so a flat
gallery's index is byte-for-byte the one it always was.
*/
string galleryIndex(scope const SourceEntry[] entries,
    in GalleryOptions opt = GalleryOptions.init) @safe pure
{
    import sparkles.docs.site_tree : buildSiteTree, directoryIndex, DirNode;

    auto tree = buildSiteTree(entries);
    return directoryIndex(tree.nodes.length ? tree.nodes[0] : DirNode.init, opt);
}

// ── mirrored-layout hrefs (GAL12) ──────────────────────────────────────────

/**
The href from the page at root-relative `from` to the page at root-relative `to`
(both `/`-separated output paths): the file name for a sibling, `../`-prefixed
across directories — `relativePath` over URL paths, so a page works wherever the
gallery is mounted.
*/
string pageHref(const(char)[] from, const(char)[] to) @safe pure
{
    auto fromDir = segments(from);
    if (fromDir.length)
        fromDir = fromDir[0 .. $ - 1]; // the page's directory, not the page
    auto toSegs = segments(to);

    size_t common;
    while (common < fromDir.length && common + 1 < toSegs.length
        && fromDir[common] == toSegs[common])
        ++common;

    auto w = appender!string;
    foreach (_; common .. fromDir.length)
        w ~= "../";
    foreach (i, seg; toSegs[common .. $])
    {
        if (i)
            w ~= "/";
        w ~= seg;
    }
    return w[];
}

/// `href`, as seen from a page `depth` directories below the gallery root: a
/// relative one gains a `../` per level, while an absolute path, a URL, or a
/// fragment is left alone (it does not depend on where the page sits).
string depthAdjustedHref(string href, size_t depth) @safe pure
{
    import std.algorithm.searching : canFind;

    if (href.length == 0 || depth == 0)
        return href;
    if (href[0] == '/' || href[0] == '#' || href.canFind("://"))
        return href;

    auto w = appender!string;
    foreach (_; 0 .. depth)
        w ~= "../";
    w ~= href;
    return w[];
}

/// How many directories below the gallery root a page at `outPath` sits.
private size_t pageDepth(scope const(char)[] outPath) @safe pure nothrow @nogc
{
    size_t n;
    foreach (char c; outPath)
        if (c == '/')
            ++n;
    return n;
}

/// `path` split on `/`, dropping empty segments (`a//b`, a trailing `/`).
private const(char)[][] segments(const(char)[] path) @safe pure nothrow
{
    const(char)[][] outp;
    size_t start;
    foreach (i, char c; path)
        if (c == '/')
        {
            if (i > start)
                outp ~= path[start .. i];
            start = i + 1;
        }
    if (start < path.length)
        outp ~= path[start .. $];
    return outp;
}

// ── the I/O seam ───────────────────────────────────────────────────────────

/**
Writes the gallery for `set` into `outDir` (`GAL2`/`GAL12`): one page per entry at
`<outDir>/<entry.outPath>`, plus an `index.html` in every directory the pages
occupy. A flat set puts every page at the top level and writes exactly one index —
the layout, and the bytes, it always had.

`renderOne` produces one entry's content fragment; an entry it fails on is
reported and $(B skipped), leaving the rest of the gallery intact (`GAL9`) — and
out of the indices, so no index ever links a page that was not written.

Returns the number of pages written.
*/
size_t writeGallery(in SourceSet set, string outDir, in GalleryOptions opt,
    scope string delegate(in SourceEntry) renderOne) @system
{
    import std.file : mkdirRecurse, write;
    import std.path : buildPath, dirName;
    import std.stdio : stderr;

    import sparkles.docs.site_tree : buildSiteTree, directoryIndex;

    mkdirRecurse(outDir);

    SourceEntry[] written;
    foreach (i, ref const e; set.entries)
    {
        string fragment;
        try
            fragment = renderOne(e);
        catch (Exception ex)
        {
            stderr.writeln("hue: skipping '", e.path, "': ", ex.msg);
            continue;
        }
        if (fragment.length == 0)
        {
            stderr.writeln("hue: skipping '", e.path, "': nothing rendered");
            continue;
        }
        // Neighbours stay the flat-sorted ones (`GAL3`/`GNV1`) — prev/next walk
        // the whole set in one order, not each directory in turn — so across a
        // directory boundary the link simply climbs out and back down.
        const prev = i > 0 ? pageHref(e.outPath, set.entries[i - 1].outPath) : "";
        const next = i + 1 < set.entries.length
            ? pageHref(e.outPath, set.entries[i + 1].outPath) : "";

        // The one thing a page's depth must change: a root-relative asset href.
        GalleryOptions pageOpt = opt;
        pageOpt.stylesheetHref = depthAdjustedHref(opt.stylesheetHref, pageDepth(e.outPath));

        const dest = buildPath(outDir, e.outPath);
        const destDir = dest.dirName;
        if (destDir != outDir)
            mkdirRecurse(destDir);
        write(dest, pageShell(e.name, e.summary, fragment, prev, next, pageOpt,
            e.relPath));
        written ~= e;
    }

    // One index per directory. An empty set still has a root node, so the
    // "no documents" index is written either way (`GAL9`).
    auto tree = buildSiteTree(written);
    if (tree.nodes.length == 0)
        write(buildPath(outDir, "index.html"), galleryIndex(null, opt));
    foreach (ref const node; tree.nodes)
    {
        const dest = node.relPath.length
            ? buildPath(outDir, node.relPath, "index.html")
            : buildPath(outDir, "index.html");
        mkdirRecurse(dest.dirName);
        write(dest, directoryIndex(node, opt));
    }
    return written.length;
}

// ---------------------------------------------------------------------------

@("gallery.pageShell.appearanceToggleUsesVitePressKeyAndOnlyWhenDual")
@safe pure
unittest
{
    import std.algorithm.searching : canFind, countUntil;

    const dual = GalleryOptions(
        chrome: ChromePalette(background: "#ffffff", border: "#dddddd",
            text: "#111111", link: "#0055cc"),
        darkChrome: ChromePalette(background: "#101010", border: "#2a2a2a",
            text: "#eeeeee", link: "#88aaff"));
    const page = pageShell("f.d", "s", "<pre class=\"syn-root\"><code>x</code></pre>",
        "", "", dual);

    // VitePress's own key, so following a link from the docs site into a
    // listing and back does not flip the theme twice per round trip.
    assert(page.canFind("vitepress-theme-appearance"), page);
    // `auto` is VitePress's "follow the OS" state and what it stores before the
    // reader has chosen, so it must behave exactly like an absent key.
    assert(page.canFind("!p || p === 'auto'"), page);

    // The class has to be applied from <head>: after </head> the page paints
    // light first and repaints dark — a flash the docs site does not have.
    const applied = page.countUntil("classList.toggle('dark'");
    const headEnd = page.countUntil("</head>");
    assert(applied >= 0 && applied < headEnd,
        "the no-flash script must run before the body");

    assert(page.canFind(`id="hue-appearance"`), page);

    // A single-theme run has nothing to toggle: no button, no script, and no
    // rules for either — dead CSS on every page otherwise.
    const single = pageShell("f.d", "s", "<pre class=\"syn-root\"><code>x</code></pre>",
        "", "", GalleryOptions(chrome: dual.chrome));
    assert(!single.canFind("hue-appearance"), single);
    assert(!single.canFind("vitepress-theme-appearance"), single);
    assert(!single.canFind("html.dark"), single);
}

@("gallery.themeChrome.followsTheThemeInsteadOfCatppuccin")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    // The bug this exists to prevent: `--theme <a light theme>` used to render a
    // light code pane inside a fixed dark surround, because the fragment and the
    // chrome were decided in different places.
    const light = resolveTheme(
        Theme(name: "light", defaultFg: Color.fromRgb(0x24, 0x29, 0x2e),
            defaultBg: Color.fromRgb(0xff, 0xff, 0xff)),
        LabelSet.fromNames(["keyword", "function"]));
    const c = themeChrome(light);

    // The surround IS the pane's background — one surface (`GAL6`).
    assert(c.background == themeBackground(light), c.background);
    assert(c.background == "#ffffff", c.background);
    assert(c.text == "#24292e", c.text);

    // Neutrals are mixes of the two, so a light theme gets light chrome: the
    // header sits just off the page, the rule is darker still, and the text
    // colours fade *toward* the background (never away from it, which is what a
    // fixed dark palette did).
    assert(c.surface == "#f2f2f2", c.surface);   // 6 % of the way to the text
    assert(c.border == "#d3d4d5", c.border);     // 20 %
    assert(c.muted == "#717477", c.muted);       // text, 35 % toward the page
    assert(c.faint == "#acaeb0", c.faint);       // text, 62 % toward the page

    // And the emitted page carries them rather than the old fixed palette.
    const page = pageShell("f.d", "d · 1 line", "<pre class=\"syn-root\"><code>x</code></pre>",
        "", "", GalleryOptions(chrome: c));
    assert(page.canFind("background: #ffffff"), page);
    assert(!page.canFind("#181825"), "the catppuccin surface leaked");
    assert(!page.canFind("#cdd6f4"), "the catppuccin text colour leaked");
    assert(!page.canFind("#6c7086"), "the catppuccin gutter colour leaked");
}

@("gallery.pageShell.darkChromeFollowsHtmlDark")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    // A two-theme run has to switch the whole surround, not just its
    // background: header, rule, links and gutter all live outside the fragment.
    const opt = GalleryOptions(
        chrome: ChromePalette(background: "#ffffff", surface: "#f0f0f0",
            border: "#dddddd", text: "#111111", muted: "#555555",
            faint: "#888888", link: "#0055cc"),
        darkChrome: ChromePalette(background: "#101010", surface: "#1a1a1a",
            border: "#2a2a2a", text: "#eeeeee", muted: "#bbbbbb",
            faint: "#777777", link: "#88aaff"));
    const page = pageShell("f.d", "s", "<pre class=\"syn-root\"><code>x</code></pre>",
        "", "", opt);

    foreach (rule; ["html.dark body, html.dark main { background: #101010",
            "html.dark body { color: #eeeeee", "html.dark header { background: #1a1a1a",
            "html.dark header a { color: #88aaff",
            "html.dark .ln::before { color: #777777"])
        assert(page.canFind(rule), rule ~ " missing from:\n" ~ page);

    // Without a dark half, nothing is emitted under `html.dark` at all.
    const single = pageShell("f.d", "s", "<pre class=\"syn-root\"><code>x</code></pre>",
        "", "", GalleryOptions(chrome: opt.chrome));
    assert(!single.canFind("html.dark"), single);
}

@("gallery.pageShell.linksASharedStylesheet")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const frag = "<pre class=\"syn-root\"><code>x\n</code></pre>\n";
    const page = pageShell("a", "", frag, "", "",
        GalleryOptions(chrome: ChromePalette(background: "#ffffff"),
            stylesheetHref: "assets/hue.css"));
    assert(page.canFind("<link rel=\"stylesheet\" href=\"assets/hue.css\">"), page);
    assert(page.canFind("background: #ffffff"), page);

    // Absent, no link is emitted at all.
    assert(!pageShell("a", "", frag, "", "").canFind("<link"));
}

@("gallery.pageShell.navSummaryAndTheme")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const frag = "<style>\n.syn-root { background-color: #123456; }\n</style>\n"
        ~ "<pre class=\"syn-root\"><code>x\n</code></pre>\n";
    const page = pageShell("02-query", "hover×2 query", frag,
        "01-hover.html", "03-completions.html",
        GalleryOptions(titlePrefix: "twoslash",
            chrome: ChromePalette(background: "#123456")));

    assert(page.canFind("<title>twoslash · 02-query</title>"), page);
    assert(page.canFind("<b>02-query</b>"), page);
    assert(page.canFind("hover×2 query"), page);
    // Both neighbours link; the index link is always present.
    assert(page.canFind("href=\"01-hover.html\""), page);
    assert(page.canFind("href=\"03-completions.html\""), page);
    assert(page.canFind("href=\"index.html\""), page);
    // The page background is taken from the theme's `.syn-root` rule.
    assert(page.canFind("background: #123456"), page);
    // Gutter + selection domains are wired.
    assert(page.canFind("counter-increment: lineno"), page);
    assert(page.canFind("sel-anno"), page);
}

@("gallery.pageShell.endsDisableRatherThanOmit")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const frag = "<pre class=\"syn-root\"><code>x\n</code></pre>\n";
    const first = pageShell("a", "", frag, "", "b.html");
    // No previous document ⇒ the link is disabled, not dropped (so the header
    // keeps its shape between pages).
    assert(first.canFind("<span class=\"prev disabled\">← prev</span>"), first);
    assert(first.canFind("href=\"b.html\""), first);

    const last = pageShell("b", "", frag, "a.html", "");
    assert(last.canFind("<span class=\"next disabled\">next →</span>"), last);

    // A neighbour in another directory is reached by a relative href, verbatim —
    // the shell appends nothing to it (`GAL12`).
    const nested = pageShell("app.d", "", frag, "../a/app.d.html", "../c/app.d.html");
    assert(nested.canFind("href=\"../a/app.d.html\""), nested);
    assert(nested.canFind("href=\"../c/app.d.html\""), nested);
    // The index link stays the sibling one, so it resolves at any depth.
    assert(nested.canFind("<a href=\"index.html\">all</a>"), nested);
}

@("gallery.pageHref.relativeAcrossDirectories")
@safe pure
unittest
{
    // Siblings at the root: the file name, exactly what the flat gallery emitted.
    assert(pageHref("a.html", "b.html") == "b.html");
    // Siblings in a subdirectory: still just the file name.
    assert(pageHref("src/a.html", "src/b.html") == "b.html");
    // Out of one directory and into another, and back up to the root.
    assert(pageHref("a/x.d.html", "b/y.d.html") == "../b/y.d.html");
    assert(pageHref("a/b/x.d.html", "top.d.html") == "../../top.d.html");
    assert(pageHref("top.d.html", "a/b/x.d.html") == "a/b/x.d.html");
    // A shared prefix is not re-descended.
    assert(pageHref("a/b/x.html", "a/c/y.html") == "../c/y.html");
    // A same-named page in a sibling directory is a different href — the
    // collision the flat layout could not express.
    assert(pageHref("a/app.d.html", "b/app.d.html") == "../b/app.d.html");
}

@("gallery.depthAdjustedHref.onlyRelativeHrefsMove")
@safe pure
unittest
{
    assert(depthAdjustedHref("assets/hue.css", 0) == "assets/hue.css");
    assert(depthAdjustedHref("assets/hue.css", 2) == "../../assets/hue.css");
    // An absolute path, a URL and a fragment do not depend on the page's depth.
    assert(depthAdjustedHref("/assets/hue.css", 3) == "/assets/hue.css");
    assert(depthAdjustedHref("https://x.example/a.css", 3) == "https://x.example/a.css");
    assert(depthAdjustedHref("#inline", 3) == "#inline");
    assert(depthAdjustedHref("", 3) == "");
}

/// The mirrored output tree (`GAL12`): a page per source path, an index per
/// directory, and two same-named files that no longer overwrite each other.
@("gallery.writeGallery.mirrorsTheSourceTree")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    import sparkles.docs.source_set : SourceEntry, SourceSet;

    const outDir = buildPath(tempDir(), "hue-gallery-mirror-" ~ randomUUID.toString);
    scope (exit)
        rmdirRecurse(outDir);

    static SourceEntry entry(string rel, string name)
        => SourceEntry(path: "src/" ~ rel, name: name, summary: "d · 1 line",
            relPath: rel, outPath: rel ~ ".html");

    const set = SourceSet(entries: [
        entry("a/app.d", "app.d"),
        entry("b/deep/app.d", "app.d"),
        entry("top.d", "top.d"),
    ]);
    const n = writeGallery(set, outDir,
        GalleryOptions(stylesheetHref: "assets/hue.css"),
        (in SourceEntry e) => "<pre class=\"syn-root\"><code>x\n</code></pre>\n");
    assert(n == 3);

    // Two same-named files, two pages.
    assert(buildPath(outDir, "a", "app.d.html").exists);
    assert(buildPath(outDir, "b", "deep", "app.d.html").exists);
    assert(buildPath(outDir, "top.d.html").exists);

    // An index in every directory — including `b`, which holds no page itself.
    foreach (dir; ["", "a", "b", buildPath("b", "deep")])
        assert(buildPath(outDir, dir, "index.html").exists, dir);

    // The shared stylesheet resolves from every depth.
    assert(readText(buildPath(outDir, "top.d.html")).canFind("href=\"assets/hue.css\""));
    assert(readText(buildPath(outDir, "a", "app.d.html"))
        .canFind("href=\"../assets/hue.css\""));
    assert(readText(buildPath(outDir, "b", "deep", "app.d.html"))
        .canFind("href=\"../../assets/hue.css\""));

    // prev/next stay the flat-sorted neighbours, reached relatively.
    const first = readText(buildPath(outDir, "a", "app.d.html"));
    assert(first.canFind("<span class=\"prev disabled\">"), first);
    assert(first.canFind("href=\"../b/deep/app.d.html\""), first);
}

/// A page `renderOne` fails on is skipped — and stays out of the indices, so a
/// directory index never links a page that was not written (`GAL9`).
@("gallery.writeGallery.skippedPagesLeaveNoDeadLinks")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    import sparkles.docs.source_set : SourceEntry, SourceSet;

    const outDir = buildPath(tempDir(), "hue-gallery-skip-" ~ randomUUID.toString);
    scope (exit)
        rmdirRecurse(outDir);

    const set = SourceSet(entries: [
        SourceEntry(path: "a/bad.d", name: "bad.d", relPath: "a/bad.d",
            outPath: "a/bad.d.html"),
        SourceEntry(path: "ok.d", name: "ok.d", relPath: "ok.d", outPath: "ok.d.html"),
    ]);
    const n = writeGallery(set, outDir, GalleryOptions.init, (in SourceEntry e) {
        if (e.name == "bad.d")
            throw new Exception("boom");
        return "<pre class=\"syn-root\"><code>x\n</code></pre>\n";
    });

    assert(n == 1);
    assert(!buildPath(outDir, "a", "bad.d.html").exists);
    // The whole `a/` node is gone with its only page — nothing links into it.
    const root = readText(buildPath(outDir, "index.html"));
    assert(!root.canFind("a/index.html"), root);
    assert(root.canFind("href=\"ok.d.html\""), root);
}

@("gallery.galleryIndex.linksEntriesAndHandlesEmpty")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const idx = galleryIndex([
        SourceEntry(path: "f/01-hover.twoslash.json", name: "01-hover", summary: "hover"),
        SourceEntry(path: "f/02-query.twoslash.json", name: "02-query", summary: "query×2"),
    ]);
    assert(idx.canFind("href=\"01-hover.html\">01-hover</a>"), idx);
    assert(idx.canFind("<code>query×2</code>"), idx);

    // An empty set says so rather than rendering an empty list.
    assert(galleryIndex([]).canFind("No documents to show"));
}

@("gallery.escaping.namesAndSummaries")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    // A name/summary carrying HTML metacharacters must not break the markup.
    const idx = galleryIndex([SourceEntry(name: "a<b>", summary: "x & \"y's\"")]);
    assert(idx.canFind("a&lt;b&gt;"), idx);
    // The apostrophe escapes too (`DOC10`): one five-entity implementation,
    // shared with every HTML writer in the repository.
    assert(idx.canFind("x &amp; &quot;y&#39;s&quot;"), idx);
}
