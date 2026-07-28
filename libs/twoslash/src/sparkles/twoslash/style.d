/**
The twoslash overlay stylesheet, ported from `@shikijs/twoslash`'s
`style-rich.css`: the `--twoslash-*` custom properties, the CSS-only `:hover`
popup interactivity (no JavaScript), the wavy-underline SVG data-URI for
`.twoslash-error`, and the completion / error / tag chrome.

The CSS is compiled in as a string import (`views/twoslash.css`) and written
verbatim by $(LREF writeTwoslashStyles), so a consumer embeds it in a `<style>`
element with no file IO — the same shape `apps/hue` uses to inline the syntax
theme stylesheet. It styles $(B only) the `.twoslash-*` chrome; syntax token
colors come from
$(REF writeThemeStylesheet, sparkles,syntax,render,html)'s `.syn-*` rules.

Pair the rendered content with a `.twoslash` container so the `:hover` selectors
match.
*/
module sparkles.twoslash.style;

import std.range.primitives : put;

/// The ported twoslash stylesheet, embedded at compile time.
enum twoslashStyleCss = import("twoslash.css");

/// Writes the twoslash overlay stylesheet (CSS text, no `<style>` wrapper) to `w`.
ref Writer writeTwoslashStyles(Writer)(return ref Writer w)
{
    put(w, twoslashStyleCss);
    return w;
}

@("style.writeTwoslashStyles.sentinels")
@safe unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import std.algorithm.searching : canFind;

    SmallBuffer!(char, 8192) buf;
    writeTwoslashStyles(buf);
    const css = buf[];

    // The import must not be empty and must carry the load-bearing selectors /
    // variables (guards against a broken string import path).
    assert(css.length > 500);
    assert(css.canFind("--twoslash-popup-bg"));
    assert(css.canFind(".twoslash-hover"));
    assert(css.canFind(".twoslash-popup-code"));
    assert(css.canFind(".twoslash-error-line"));
    assert(css.canFind(".twoslash-highlighted"));
    assert(css.canFind(".twoslash-completion-list"));
    assert(css.canFind(".twoslash-tag-line"));
}

/// An RGBA quadruple, for comparing CSS hex spellings to the D palette by value
/// (so `#8888` and `#88888888` compare equal).
private struct Rgba
{
    ubyte r, g, b, a;
}

/// Parses a CSS hex color (`#RGB` / `#RGBA` / `#RRGGBB` / `#RRGGBBAA`) to $(LREF Rgba).
private Rgba parseCssHex(scope const(char)[] s) @safe pure
{
    assert(s.length && s[0] == '#');
    const h = s[1 .. $];

    ubyte nib(char c)
    {
        if (c >= '0' && c <= '9')
            return cast(ubyte)(c - '0');
        if (c >= 'a' && c <= 'f')
            return cast(ubyte)(c - 'a' + 10);
        if (c >= 'A' && c <= 'F')
            return cast(ubyte)(c - 'A' + 10);
        assert(0, "not a hex digit");
    }

    ubyte dup1(char c) => cast(ubyte)(nib(c) << 4 | nib(c));   // "8" → 0x88
    ubyte pair(char hi, char lo) => cast(ubyte)(nib(hi) << 4 | nib(lo));

    switch (h.length)
    {
        case 3:
            return Rgba(dup1(h[0]), dup1(h[1]), dup1(h[2]), 0xFF);
        case 4:
            return Rgba(dup1(h[0]), dup1(h[1]), dup1(h[2]), dup1(h[3]));
        case 6:
            return Rgba(pair(h[0], h[1]), pair(h[2], h[3]), pair(h[4], h[5]), 0xFF);
        case 8:
            return Rgba(pair(h[0], h[1]), pair(h[2], h[3]), pair(h[4], h[5]), pair(h[6], h[7]));
        default:
            assert(0, "unexpected hex length");
    }
}

/// Collects `--name: #hex;` declarations from `block` into a `name → Rgba` map
/// (non-`#` values, e.g. `inherit`/`currentColor`/`sans-serif`, are skipped).
private Rgba[string] cssColorVars(scope const(char)[] block) @safe
{
    import std.string : indexOf, splitLines, strip;

    Rgba[string] vars;
    foreach (line; block.splitLines)
    {
        const t = line.strip;
        if (t.length < 2 || t[0 .. 2] != "--")
            continue;
        const colon = t.indexOf(':');
        if (colon < 0)
            continue;
        const name = t[0 .. colon].strip;
        auto value = t[colon + 1 .. $].strip;
        if (value.length && value[$ - 1] == ';')
            value = value[0 .. $ - 1].strip;
        if (value.length && value[0] == '#')
            vars[name.idup] = parseCssHex(value);
    }
    return vars;
}

/**
The palette lockstep: the D $(REF defaultTwoslashPalette, sparkles,ui,style) and
the hand-authored `:root` block of `views/twoslash.css` must agree on every
palette-owned `--twoslash-*` color, so the GUI/TUI palette can never silently
drift from the shipped stylesheet. Compares by parsed RGBA value, so hex
spellings (`#8888` vs `#88888888`) don't matter.
*/
@("style.twoslashCss.paletteLockstep")
@safe unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette, writeTwoslashVars;
    import std.string : indexOf;

    // Extract the FIRST (light) `:root { … }` block from the stylesheet.
    const css = twoslashStyleCss;
    const rootAt = css.indexOf(":root");
    assert(rootAt >= 0);
    const open = css.indexOf('{', rootAt);
    const close = css.indexOf('}', open);
    assert(open >= 0 && close > open);
    auto cssVars = cssColorVars(css[open + 1 .. close]);

    // Generate the same vars from the D palette and parse them back.
    SmallBuffer!(char, 2048) buf;
    writeTwoslashVars(buf, defaultTwoslashPalette());
    auto genVars = cssColorVars(buf[]);

    // Every palette-owned var must be present in the CSS with the same value.
    assert(genVars.length >= 12);
    foreach (name, expected; genVars)
    {
        const inCss = name in cssVars;
        assert(inCss !is null, "CSS is missing palette var " ~ name);
        assert(*inCss == expected, "palette/CSS drift on " ~ name);
    }

    // The dark `@media` block (the SECOND `:root`) overrides only popup-bg +
    // docs-color; those must match the dark palette variant.
    const darkAt = css.indexOf(":root", close);
    assert(darkAt >= 0, "no dark :root block");
    const dOpen = css.indexOf('{', darkAt);
    const dClose = css.indexOf('}', dOpen);
    auto darkCss = cssColorVars(css[dOpen + 1 .. dClose]);
    assert(darkCss.length >= 2);

    SmallBuffer!(char, 2048) dbuf;
    writeTwoslashVars(dbuf, defaultTwoslashPalette(ColorScheme.dark));
    auto darkGen = cssColorVars(dbuf[]);
    foreach (name, expected; darkCss)
    {
        const inGen = name in darkGen;
        assert(inGen !is null && *inGen == expected, "dark palette/CSS drift on " ~ name);
    }
}
