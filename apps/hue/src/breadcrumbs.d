/**
Path breadcrumbs for a generated page (`GAL14`).

A mirrored gallery (`GAL12`) puts pages at arbitrary depth, and the header's
`all` link only reaches the directory index beside the page — from
`libs/base/src/sparkles/base/smallbuffer.d.html` there is no way back to
`libs/base` short of the browser's back button. Breadcrumbs are the way up.

$(B Why this is D and not a Vue component.) The VitePress prototype rendered
these with `docs/.vitepress/theme/Breadcrumbs.vue`, which only works for pages
VitePress itself builds. hue's pages are static HTML written outside it, so a
component cannot reach them; and keeping both would mean the same widget
implemented twice, drifting. This module is the single implementation — it
reproduces the component's markup, class names and behaviour so the two are
interchangeable while the docs site still has both kinds of page.

Interactivity is ~30 lines of vanilla JS ($(LREF breadcrumbScript)) rather than
a framework: copy-to-clipboard and a 2-second label swap.
*/
module breadcrumbs;

import std.array : appender, Appender;

import gallery : ChromePalette, escapeInto;

/**
One path segment.

`copyText` is the path up to $(I and including) this segment, which is what the
component copies — clicking `base` in `libs/base/src` yields `libs/base`, not
`base`. The last segment's `copyText` is therefore the whole path, and the
always-visible "Copy Path" button reuses it rather than recomputing.
*/
struct Breadcrumb
{
    string text;      /// the segment, as shown
    string href;      /// its directory index, relative to the page; empty for the last
    string copyText;  /// the path up to and including it
    string gitHubUrl; /// its page on the forge, when a repo URL is configured
}

/**
The trail for a page at `relPath` (a gallery-root-relative path such as
`libs/base/src/x.d`).

Every segment but the last links to that directory's `index.html`, resolved
$(B relative to the page) — a page three deep reaches its grandparent through
`../../index.html` — so the tree is navigable from a `file://` URL, with no
base href and no server.

`repoUrl` is a blob base like
`https://github.com/PetarKirov/sparkles/blob/main`; empty leaves `gitHubUrl`
unset and the forge links unrendered, since a gallery of a directory that is
not in a repository has nowhere to point.
*/
Breadcrumb[] breadcrumbsFor(scope const(char)[] relPath,
    scope const(char)[] repoUrl = null, scope const(char)[] repoPrefix = null) @safe pure
{
    import std.string : indexOf;

    Breadcrumb[] crumbs;
    size_t start;
    // Count the separators first: a segment's href needs to know how many
    // levels sit *below* it, which is only knowable once the whole path is
    // split.
    size_t total = 1;
    foreach (ch; relPath)
        if (ch == '/')
            ++total;

    size_t i;
    while (start <= relPath.length)
    {
        const rest = relPath[start .. $];
        const slash = rest.indexOf('/');
        const end = slash < 0 ? relPath.length : start + slash;
        const seg = relPath[start .. end];
        if (seg.length)
        {
            const isLast = i + 1 == total;
            crumbs ~= Breadcrumb(
                text: seg.idup,
                href: isLast ? null : upTo(total - 1 - i),
                copyText: relPath[0 .. end].idup,
                gitHubUrl: repoUrl.length
                    ? joinUrl(repoUrl, repoPrefix, relPath[0 .. end]) : null,
            );
        }
        if (slash < 0)
            break;
        start = end + 1;
        ++i;
    }
    return crumbs;
}

/// `../` repeated `levels` times plus `index.html`; `index.html` at zero.
private string upTo(size_t levels) @safe pure
{
    auto w = appender!string;
    foreach (_; 0 .. levels)
        w ~= "../";
    w ~= "index.html";
    return w[];
}

/// `base`, then the optional in-repo `prefix`, then `path` — single-slashed.
private string joinUrl(scope const(char)[] base, scope const(char)[] prefix,
    scope const(char)[] path) @safe pure
{
    auto w = appender!string;
    void seg(scope const(char)[] s)
    {
        if (!s.length)
            return;
        if (w[].length && w[][$ - 1] != '/' && s[0] != '/')
            w ~= '/';
        w ~= s[0] == '/' && w[].length && w[][$ - 1] == '/' ? s[1 .. $] : s;
    }

    seg(base);
    seg(prefix);
    seg(path);
    return w[];
}

/**
Renders the trail into `w`.

Markup, class names and DOM order match `Breadcrumbs.vue`: a `.breadcrumbs-list`
of `/`-separated `.breadcrumb-segment-wrapper`s, each with a hover
`.breadcrumb-tooltip` carrying Copy and (optionally) GitHub, followed by the
always-visible `.breadcrumb-copy-all-group`. A page identical but for the
renderer should be indistinguishable.

A `Home` segment is dropped, as the component does — the gallery root already
has its own `all` link, and a leading "Home /" is noise on every page.
*/
void renderBreadcrumbs(ref Appender!string w, scope const Breadcrumb[] crumbs) @safe pure
{
    if (!crumbs.length)
        return;

    w ~= `<nav class="breadcrumbs-container" aria-label="Breadcrumb">`;
    w ~= `<div class="breadcrumbs-list">`;
    size_t shown;
    foreach (ref c; crumbs)
    {
        if (c.text == "Home")
            continue;
        if (shown)
            w ~= `<span class="breadcrumb-separator">/</span>`;
        ++shown;
        w ~= `<div class="breadcrumb-segment-wrapper">`;
        if (c.href.length)
        {
            w ~= `<a class="breadcrumb-segment-link" href="`;
            escapeInto(w, c.href);
            w ~= `"><code>`;
            escapeInto(w, c.text);
            w ~= `</code></a>`;
        }
        else
        {
            w ~= `<span class="breadcrumb-segment-text"><code>`;
            escapeInto(w, c.text);
            w ~= `</code></span>`;
        }
        if (c.copyText.length)
        {
            w ~= `<div class="breadcrumb-tooltip"><div class="breadcrumb-tooltip-inner">`;
            w ~= `<button class="breadcrumb-tooltip-btn" data-copy="`;
            escapeInto(w, c.copyText);
            w ~= `" aria-label="Copy path up to `;
            escapeInto(w, c.text);
            w ~= `">`;
            w ~= copyIcon;
            w ~= `<span>Copy</span></button>`;
            if (c.gitHubUrl.length)
            {
                w ~= `<span class="breadcrumb-tooltip-divider">|</span>`;
                w ~= `<a class="breadcrumb-tooltip-link" target="_blank" rel="noopener noreferrer" href="`;
                escapeInto(w, c.gitHubUrl);
                w ~= `" aria-label="Open `;
                escapeInto(w, c.text);
                w ~= ` on GitHub">`;
                w ~= linkIcon;
                w ~= `<span>GitHub</span></a>`;
            }
            w ~= `</div></div>`;
        }
        w ~= `</div>`;
    }
    w ~= `</div>`;

    // The whole path, always visible — the component's `copyAll`, which reuses
    // the last segment's `copyText` rather than recomputing the join.
    const last = crumbs[$ - 1];
    w ~= `<div class="breadcrumb-copy-all-group">`;
    w ~= `<button class="breadcrumb-copy-all-btn" title="Copy entire path" `;
    w ~= `aria-label="Copy entire path" data-copy="`;
    escapeInto(w, last.copyText);
    w ~= `">`;
    w ~= copyIcon14;
    w ~= `<span class="copy-all-label">Copy Path</span></button>`;
    if (last.gitHubUrl.length)
    {
        w ~= `<span class="breadcrumb-copy-all-divider">|</span>`;
        w ~= `<a class="breadcrumb-copy-all-link" target="_blank" rel="noopener noreferrer" `;
        w ~= `title="Open on GitHub" aria-label="Open on GitHub" href="`;
        escapeInto(w, last.gitHubUrl);
        w ~= `">`;
        w ~= linkIcon14;
        w ~= `<span class="copy-all-label">GitHub</span></a>`;
    }
    w ~= `</div></nav>`;
}

/// The component's clipboard icon, inlined — a `<use>` reference would need a
/// sprite sheet, and an external file breaks a `file://` page.
private enum copyIcon = svgOpen(12) ~
    `<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>` ~
    `<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>`;

/// ditto, at the copy-all group's size
private enum copyIcon14 = svgOpen(14) ~
    `<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>` ~
    `<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>`;

/// The component's external-link icon.
private enum linkIcon = svgOpen(12) ~
    `<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>` ~
    `<polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>`;

/// ditto, at the copy-all group's size
private enum linkIcon14 = svgOpen(14) ~
    `<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>` ~
    `<polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>`;

/// The shared `<svg>` attributes, so the four icons cannot drift apart.
private string svgOpen(int px) @safe pure
{
    import std.conv : text;

    return text(`<svg xmlns="http://www.w3.org/2000/svg" width="`, px,
        `" height="`, px, `" viewBox="0 0 24 24" fill="none" stroke="currentColor"`,
        ` stroke-width="2" stroke-linecap="round" stroke-linejoin="round">`);
}

/**
The trail's CSS, from `chrome` (`GAL6`) — so breadcrumbs follow the theme like
everything else around the pane.

`dark` is emitted under `html.dark` when a two-theme run supplies one.
*/
string breadcrumbCss(in ChromePalette c, in ChromePalette dark = ChromePalette.init) @safe pure
{
    import std.conv : text;

    auto w = appender!string;
    w ~= "  .breadcrumbs-container { display: flex; align-items: center; flex-wrap: wrap;\n";
    w ~= "                           gap: 12px; font-size: 14px; }\n";
    w ~= "  .breadcrumbs-list { display: flex; align-items: center; flex-wrap: wrap; gap: 1px; }\n";
    w ~= text("  .breadcrumb-separator { color: ", c.faint, "; margin: 0 2px; }\n");
    // The wrapper is the tooltip's positioning context, and its padding-bottom
    // bridges the gap to the tooltip so moving the pointer down does not cross
    // dead space and dismiss it.
    w ~= "  .breadcrumb-segment-wrapper { position: relative; padding-bottom: 6px; }\n";
    w ~= text("  .breadcrumb-segment-link { color: ", c.link, "; text-decoration: none; }\n");
    w ~= text("  .breadcrumb-segment-text { color: ", c.text, "; }\n");
    w ~= "  .breadcrumb-segment-wrapper code { font-size: 0.92em; }\n";
    w ~= "  .breadcrumb-segment-link:hover code { text-decoration: underline; }\n";
    w ~= "  .breadcrumb-tooltip { position: absolute; top: 100%; left: 50%;\n";
    w ~= "                        transform: translateX(-50%); z-index: 10;\n";
    w ~= "                        opacity: 0; visibility: hidden; transition: opacity .12s; }\n";
    w ~= "  .breadcrumb-segment-wrapper:hover .breadcrumb-tooltip,\n";
    w ~= "  .breadcrumb-segment-wrapper:focus-within .breadcrumb-tooltip {\n";
    w ~= "    opacity: 1; visibility: visible; }\n";
    w ~= text("  .breadcrumb-tooltip-inner { display: flex; align-items: center; gap: 6px;\n");
    w ~= text("    white-space: nowrap; background: ", c.surface, "; color: ", c.text, ";\n");
    w ~= text("    border: 1px solid ", c.border, "; border-radius: 6px; padding: 4px 8px; }\n");
    w ~= text("  .breadcrumb-tooltip-btn, .breadcrumb-tooltip-link,\n");
    w ~= text("  .breadcrumb-copy-all-btn, .breadcrumb-copy-all-link {\n");
    w ~= text("    display: inline-flex; align-items: center; gap: 4px; background: none;\n");
    w ~= text("    border: 0; padding: 0; cursor: pointer; font: inherit; color: ",
        c.link, "; text-decoration: none; }\n");
    w ~= text("  .breadcrumb-tooltip-divider, .breadcrumb-copy-all-divider { color: ",
        c.faint, "; }\n");
    w ~= text("  .breadcrumb-copy-all-group { display: flex; align-items: center; gap: 8px;\n");
    w ~= text("    border: 1px solid ", c.border, "; border-radius: 6px; padding: 3px 8px; }\n");
    if (dark.background.length)
    {
        w ~= text("  html.dark .breadcrumb-separator,\n");
        w ~= text("  html.dark .breadcrumb-tooltip-divider,\n");
        w ~= text("  html.dark .breadcrumb-copy-all-divider { color: ", dark.faint, "; }\n");
        w ~= text("  html.dark .breadcrumb-segment-link,\n");
        w ~= text("  html.dark .breadcrumb-tooltip-btn, html.dark .breadcrumb-tooltip-link,\n");
        w ~= text("  html.dark .breadcrumb-copy-all-btn,\n");
        w ~= text("  html.dark .breadcrumb-copy-all-link { color: ", dark.link, "; }\n");
        w ~= text("  html.dark .breadcrumb-segment-text { color: ", dark.text, "; }\n");
        w ~= text("  html.dark .breadcrumb-tooltip-inner { background: ", dark.surface,
            "; color: ", dark.text, "; border-color: ", dark.border, "; }\n");
        w ~= text("  html.dark .breadcrumb-copy-all-group { border-color: ",
            dark.border, "; }\n");
    }
    return w[];
}

/**
The component's behaviour, as vanilla JS: copy the button's `data-copy`, swap
its label to `Copied!` for two seconds, and restore it.

One delegated listener rather than one per button, so the cost does not scale
with path depth. The two feedback states are mutually exclusive in the
component (copying a segment clears a copy-all "Copied!"), which falls out of
resetting every label before setting one.
*/
enum breadcrumbScript =
    "document.addEventListener('click', e => {\n" ~
    "  const b = e.target.closest('[data-copy]');\n" ~
    "  if (!b) return;\n" ~
    "  e.preventDefault(); e.stopPropagation();\n" ~
    // `navigator.clipboard` is undefined on an insecure origin, which includes
    // `file://` in some browsers — the gallery's most likely home. Bail rather
    // than throw, so the label does not lie about having copied.
    "  if (!navigator.clipboard) return;\n" ~
    "  navigator.clipboard.writeText(b.dataset.copy).then(() => {\n" ~
    "    document.querySelectorAll('[data-copy] span').forEach(s => {\n" ~
    "      if (s.dataset.was) { s.textContent = s.dataset.was; delete s.dataset.was; }\n" ~
    "    });\n" ~
    "    const s = b.querySelector('span');\n" ~
    "    if (!s) return;\n" ~
    "    s.dataset.was = s.textContent;\n" ~
    "    s.textContent = 'Copied!';\n" ~
    "    setTimeout(() => {\n" ~
    "      if (s.dataset.was) { s.textContent = s.dataset.was; delete s.dataset.was; }\n" ~
    "    }, 2000);\n" ~
    "  });\n" ~
    "});\n";

// ---------------------------------------------------------------------------

@("breadcrumbs.breadcrumbsFor.linksEachAncestorRelativeToThePage")
@safe pure
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;

    const c = breadcrumbsFor("libs/base/src/x.d");
    assert(c.map!(b => b.text).array == ["libs", "base", "src", "x.d"]);

    // Hrefs are relative to the PAGE, which sits three directories deep — so
    // `libs` is three `../` up. Anything root-relative would break on a
    // `file://` URL and under a docs site served from a subpath.
    assert(c[0].href == "../../../index.html", c[0].href);
    assert(c[1].href == "../../index.html", c[1].href);
    assert(c[2].href == "../index.html", c[2].href);
    // The page itself is where you already are.
    assert(c[3].href == "", c[3].href);

    // Copying a segment yields the path up to it, not the segment alone.
    assert(c.map!(b => b.copyText).array
        == ["libs", "libs/base", "libs/base/src", "libs/base/src/x.d"]);

    // A file at the root has one segment and no ancestors.
    const top = breadcrumbsFor("dub.sdl");
    assert(top.length == 1 && top[0].href == "" && top[0].copyText == "dub.sdl");

    assert(breadcrumbsFor("") == []);
}

@("breadcrumbs.breadcrumbsFor.forgeUrlsAreOptionalAndSingleSlashed")
@safe pure
unittest
{
    const none = breadcrumbsFor("a/b.d");
    assert(none[0].gitHubUrl == "" && none[1].gitHubUrl == "",
        "no repo URL means no forge links — a gallery of a plain directory has "
        ~ "nowhere to point");

    // A trailing slash on the base, or a prefix, must not double up.
    const c = breadcrumbsFor("a/b.d", "https://github.com/o/r/blob/main/");
    assert(c[0].gitHubUrl == "https://github.com/o/r/blob/main/a", c[0].gitHubUrl);
    assert(c[1].gitHubUrl == "https://github.com/o/r/blob/main/a/b.d", c[1].gitHubUrl);

    const p = breadcrumbsFor("x.d", "https://github.com/o/r/blob/main", "libs/base");
    assert(p[0].gitHubUrl == "https://github.com/o/r/blob/main/libs/base/x.d",
        p[0].gitHubUrl);
}

@("breadcrumbs.renderBreadcrumbs.matchesTheVueComponentsContract")
@safe pure
unittest
{
    import std.algorithm.searching : canFind, countUntil;

    auto w = appender!string;
    renderBreadcrumbs(w, breadcrumbsFor("libs/x.d", "https://github.com/o/r/blob/main"));
    const html = w[];

    // The class names the parked Breadcrumbs.vue used, so the two renderers are
    // interchangeable while the docs site still has both kinds of page.
    foreach (cls; ["breadcrumbs-container", "breadcrumbs-list", "breadcrumb-separator",
            "breadcrumb-segment-wrapper", "breadcrumb-segment-link",
            "breadcrumb-segment-text", "breadcrumb-tooltip", "breadcrumb-tooltip-inner",
            "breadcrumb-tooltip-btn", "breadcrumb-tooltip-divider",
            "breadcrumb-tooltip-link", "breadcrumb-copy-all-group",
            "breadcrumb-copy-all-btn", "breadcrumb-copy-all-divider",
            "breadcrumb-copy-all-link", "copy-all-label"])
        assert(html.canFind(cls), cls ~ " missing from:\n" ~ html);

    // Exactly one separator between two segments, and none leading.
    assert(html.countUntil(`class="breadcrumb-separator"`) > html.countUntil("libs"),
        "the separator must sit between segments, not before the first");

    // The copy-all button carries the WHOLE path, which is the last segment's
    // copyText — not the last segment alone.
    assert(html.canFind(`class="breadcrumb-copy-all-btn" title="Copy entire path" ` ~
        `aria-label="Copy entire path" data-copy="libs/x.d"`), html);

    // Forge links never open in-place, and carry the noopener pair.
    assert(html.canFind(`target="_blank" rel="noopener noreferrer"`), html);
}

@("breadcrumbs.renderBreadcrumbs.dropsHomeAndEscapes")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    auto w = appender!string;
    renderBreadcrumbs(w, [
        Breadcrumb(text: "Home", href: "../index.html", copyText: "Home"),
        Breadcrumb(text: "a&b", copyText: `a&b<"'`),
    ]);
    const html = w[];

    // The component filtered `Home` out; a leading "Home /" is noise on every
    // page and the gallery root already has its own link.
    assert(!html.canFind(">Home<"), html);
    assert(!html.canFind("breadcrumb-separator"),
        "with Home dropped there is one segment left, so no separator");

    // Both the text and the data attribute are escaped — `copyText` lands in an
    // HTML attribute, so an unescaped quote would end it.
    assert(html.canFind("a&amp;b"), html);
    assert(html.canFind(`data-copy="a&amp;b&lt;&quot;'"`), html);
}

@("breadcrumbs.breadcrumbCss.followsTheChromeAndItsDarkHalf")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const light = ChromePalette(background: "#ffffff", surface: "#f2f2f2",
        border: "#d3d4d5", text: "#111111", muted: "#717477", faint: "#acaeb0",
        link: "#0055cc");
    const css = breadcrumbCss(light);
    assert(css.canFind(".breadcrumb-segment-link { color: #0055cc"), css);
    assert(css.canFind(".breadcrumb-separator { color: #acaeb0"), css);
    assert(!css.canFind("html.dark"), "no dark half was supplied");

    const dark = ChromePalette(background: "#101010", surface: "#1a1a1a",
        border: "#2a2a2a", text: "#eeeeee", muted: "#bbbbbb", faint: "#777777",
        link: "#88aaff");
    const dual = breadcrumbCss(light, dark);
    assert(dual.canFind("html.dark .breadcrumb-tooltip-inner { background: #1a1a1a"), dual);
}
