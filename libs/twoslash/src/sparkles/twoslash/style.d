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
