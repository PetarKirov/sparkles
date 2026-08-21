/**
The doc-site **options vocabulary** every `sparkles:docs` module shares:
presentation knobs ($(LREF GalleryOptions) / $(LREF SiteOptions)), the page
chrome ($(LREF ChromePalette)) with its theme derivation ($(LREF themeChrome),
`GAL6`/`HTM7` — pane and surround are one surface by construction), and the
HTML escaping every builder uses ($(LREF escapeInto)).

This module sits at the bottom of the package's import graph — `fragment`,
`breadcrumbs`, `site_tree` and `page_shell` all import it — so it holds only
plain data and pure string builders.
*/
module sparkles.docs.options;

import std.array : appender, Appender;

import sparkles.base.text.html : writeHtmlEscaped;
import sparkles.syntax;

/// Presentation knobs for a gallery — the page-title prefix and the index copy.
struct GalleryOptions
{
    string titlePrefix = "hue";                     /// `<title>` prefix per page
    string heading = "hue gallery";                 /// the index's `<h1>`
    string indexTitle;                              /// the index's `<title>` (default: `heading`)
    string blurb = "Rendered by <code>hue</code>."; /// the index's lead paragraph (raw HTML)

    /**
    The page chrome (`GAL6`) — pass $(LREF themeChrome) of the theme the
    fragments were rendered with, so the pane and everything around it are one
    surface.

    The background half of this used to be scraped back out of each fragment's
    own `<style>` block, and the rest was a catppuccin palette hardcoded in
    `pageShell`. A fragment need not carry a style block any more
    (`FragmentOptions.embedStyles`), and a scraper that silently falls back to a
    fixed colour turns that into a visual regression no test catches — so the
    caller states it.
    */
    ChromePalette chrome = ChromePalette(
        background: defaultBackground,
        surface: "#181825",
        border: "#313244",
        text: "#cdd6f4",
        muted: "#a6adc8",
        faint: "#6c7086",
        link: "#89b4fa",
    );

    /// the same, for the dark half of a two-theme run — the chrome has to
    /// follow `html.dark` too, or the pane and the page come apart the moment
    /// the switch is flipped. Unset leaves the light chrome in both schemes.
    ChromePalette darkChrome;

    /// `true` iff a dark half was supplied.
    bool hasDarkChrome() const scope @safe pure nothrow @nogc
        => darkChrome.background.length != 0;

    /**
    Linked from `<head>` when set — the shared stylesheet the fragments leave
    their rules to.

    In a mirrored gallery (`GAL12`) pages sit at varying depths, so this is the
    href $(B as seen from the gallery root); $(LREF writeGallery) rewrites it per
    page with $(LREF depthAdjustedHref) rather than making every caller compute
    one href per depth.
    */
    string stylesheetHref;

    /**
    Blob base for the forge links in the breadcrumb trail (`GAL14`) — e.g.
    `https://github.com/PetarKirov/sparkles/blob/main`.

    Unset renders the trail without forge links rather than guessing a remote:
    a gallery of a directory that is not in a repository has nowhere to point.
    */
    string repoUrl;

    /// The gallery root's path inside that repository, when the two differ —
    /// `hue gallery libs/base` from the repo root makes the pages' `src/x.d`
    /// the repo's `libs/base/src/x.d`.
    string repoPrefix;

    /**
    Pre-rendered site-sidebar markup (`DOC8`) — `sidebar.sidebarNav` of the
    docs site's `sidebar.json` — spliced into every page and directory index
    when set, so a listing carries the same navigation as the site around it.

    A $(I string), not the tree: this module stays at the bottom of the
    package's import graph, and the caller resolves the links (site base URL)
    once rather than every page resolving them again.
    */
    string sidebarHtml;
}

/**
The name reserved for the successor of $(LREF GalleryOptions) once a whole
$(I site) — not just one gallery — has its own knobs (the planned
`docs/specs/docs/` site spec).

An alias, not a second struct: the site's field set has not settled, and two
structs today would only buy a conversion function. When it lands it renames
this and `GalleryOptions` becomes the alias (or goes away).
*/
alias SiteOptions = GalleryOptions;

/// The backdrop for a theme that declares no background of its own.
enum defaultBackground = "#1e1e2e";

/**
The page chrome's colours, as `#rrggbb` (`GAL6`/`HTM7`).

Everything outside the code pane — the header bar, its rule, the nav links, the
line-number gutter — used to be a fixed catppuccin palette written into
`pageShell`. That is wrong for every other theme: `hue gallery --theme
github-light` produced a light code pane inside dark chrome, and no test could
see it because the fragment and the surround were decided in different places.

$(LREF themeChrome) derives one from the theme instead, so the two agree by
construction; `--chrome=site` will supply the docs site's own palette here
without `pageShell` learning about either.
*/
struct ChromePalette
{
    string background;  /// page + pane surround — one surface with the code
    string surface;     /// the header bar
    string border;      /// the rule under it
    string text;        /// body text
    string muted;       /// a page's summary / kind tally
    string faint;       /// a disabled nav link, and the line-number gutter
    string link;        /// prev · index · next
}

/**
Derives $(LREF ChromePalette) from `theme`'s own colours.

Only two inputs are load-bearing: the theme's default background and
foreground. Every neutral is a mix of the two, so the chrome tracks any
theme — light or dark — without a table of per-theme values to maintain, and
`background` is $(LREF themeBackground) exactly, so the surround and the pane
cannot disagree.

The one colour that cannot be mixed is `link`, which needs a hue: it is the
theme's own `function` style, since a theme that highlights code at all styles
that one. A theme that does not falls back to `text`, which is legible on
`surface` by construction.
*/
ChromePalette themeChrome(in ResolvedTheme theme) @safe pure
{
    RgbColor bg, fg;
    if (!concreteRgb(theme.defaults.bg, bg))
        bg = RgbColor(0x1e, 0x1e, 0x2e);
    if (!concreteRgb(theme.defaults.fg, fg))
        fg = RgbColor(0xcd, 0xd6, 0xf4);

    RgbColor link = fg;
    const id = theme.labels.resolve("function");
    if (id)
        cast(void) concreteRgb(theme[id].fg, link);

    return ChromePalette(
        background: hexRgb(bg),
        surface: hexRgb(mixRgb(bg, fg, 0.06)),
        border: hexRgb(mixRgb(bg, fg, 0.20)),
        text: hexRgb(fg),
        muted: hexRgb(mixRgb(fg, bg, 0.35)),
        faint: hexRgb(mixRgb(fg, bg, 0.62)),
        link: hexRgb(link),
    );
}

/// `t` of the way from `a` to `b`, per channel.
private RgbColor mixRgb(RgbColor a, RgbColor b, double t) @safe pure nothrow @nogc
{
    static ubyte lerp(ubyte x, ubyte y, double t) @safe pure nothrow @nogc
    {
        const v = x + (cast(double) y - x) * t;
        return cast(ubyte)(v < 0 ? 0 : (v > 255 ? 255 : v + 0.5));
    }

    return RgbColor(lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t));
}

/// `#rrggbb`.
private string hexRgb(RgbColor c) @safe pure
{
    import sparkles.base.text.writers : writeHexByte;

    auto w = appender!string;
    w ~= '#';
    writeHexByte(w, c.r);
    writeHexByte(w, c.g);
    writeHexByte(w, c.b);
    return w[];
}

/**
The background `theme`'s stylesheet puts on `.syn-root`, as `#rrggbb` — the
colour a page surround must use to be one surface with the code pane (`GAL6`);
$(LREF defaultBackground) when the theme declares none.

It asks `sparkles:syntax`'s `concreteRgb` rather than re-deciding which colours
produce a declaration, so this can never disagree with the emitted CSS.
*/
string themeBackground(in ResolvedTheme theme) @safe pure
{
    import sparkles.base.text.writers : writeHexByte;

    RgbColor rgb;
    if (!concreteRgb(theme.defaults.bg, rgb))
        return defaultBackground;

    auto w = appender!string;
    w ~= '#';
    writeHexByte(w, rgb.r);
    writeHexByte(w, rgb.g);
    writeHexByte(w, rgb.b);
    return w[];
}

/// Escapes `&`, `<`, `>`, `"`, `'` into `w` — the package's shared spelling of
/// `sparkles.base.text.html.writeHtmlEscaped`, so the repository has exactly
/// one HTML-escaping implementation
/// ([`DOC10`](../../../../../docs/specs/docs/site.md)). The fifth entity
/// (`'` → `&#39;`) is the deliberate byte change that row records: this module
/// once carried its own four-entity copy.
void escapeInto(ref Appender!string w, scope const(char)[] s) @safe pure
    => writeHtmlEscaped(w, s);

// ---------------------------------------------------------------------------

@("gallery.themeChrome.takesItsLinkHueFromTheThemeAndDegrades")
@safe pure
unittest
{
    // `link` is the one colour a mix cannot produce, so it comes from the
    // theme's own `function` style.
    auto theme = Theme(name: "t", defaultFg: Color.fromRgb(0xcd, 0xd6, 0xf4),
        defaultBg: Color.fromRgb(0x1e, 0x1e, 0x2e));
    theme.rules ~= ThemeRule("function", StyleSpec(fg: Color.fromRgb(0x89, 0xb4, 0xfa)));
    const c = themeChrome(resolveTheme(theme, LabelSet.fromNames(["function"])));
    assert(c.link == "#89b4fa", c.link);

    // A theme that styles no functions falls back to the body text, which is
    // legible on `surface` by construction — never to a hardcoded blue.
    const bare = themeChrome(resolveTheme(
        Theme(name: "b", defaultFg: Color.fromRgb(0x11, 0x22, 0x33),
            defaultBg: Color.fromRgb(0xee, 0xee, 0xee)),
        LabelSet.fromNames(["keyword"])));
    assert(bare.link == bare.text, bare.link);
}

@("gallery.themeBackground.matchesTheEmittedRule")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    // The colour must be the one the stylesheet actually writes on `.syn-root`
    // — the invariant the old fragment-scraping `synRootBackground` stood for.
    const theme = Theme(name: "t", defaultFg: Color.fromRgb(0xcd, 0xd6, 0xf4),
        defaultBg: Color.fromRgb(0x1e, 0x1e, 0x2e));
    const resolved = resolveTheme(theme, LabelSet.fromNames(["keyword"]));
    auto sheet = appender!string;
    writeThemeStylesheet(resolved, sheet);
    assert(sheet[].canFind("background-color:" ~ themeBackground(resolved)), sheet[]);

    // A theme with no background of its own falls back rather than inventing one
    // (its stylesheet declares no `background-color` to match).
    const bare = resolveTheme(Theme(name: "b"), LabelSet.fromNames(["keyword"]));
    assert(themeBackground(bare) == defaultBackground);

    // A palette colour concretizes exactly as the CSS does.
    const pal = resolveTheme(Theme(name: "p", defaultBg: Color.fromPalette(8)),
        LabelSet.fromNames(["keyword"]));
    auto palSheet = appender!string;
    writeThemeStylesheet(pal, palSheet);
    assert(palSheet[].canFind("background-color:" ~ themeBackground(pal)), palSheet[]);
}
