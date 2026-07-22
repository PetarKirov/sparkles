/**
Completion-kind icons for the HTML overlay — the `<span class="twoslash-completions-icon
completions-{kind}">` glyphs `@shikijs/twoslash`'s `rendererRich` draws before each
completion candidate.

Two built-in strategies (chosen via
$(REF TwoslashHtmlOptions.completionIcons, sparkles,twoslash,render_html)):

$(LIST
    * $(B svg) — the reference inline SVGs, ported verbatim from Shiki's
        `icons-completions.json` and string-imported from `views/icons/completions/*.svg`.
        Self-contained (each path is `fill="currentColor"`; sized to `1em` by the
        stylesheet), so they inherit the theme's text color with no external assets.
    * $(B glyph) — a single Unicode glyph per kind, for terminals-of-the-web / minimal output.
)

An unknown kind falls back to `property` (svg) / `•` (glyph), matching Shiki.
*/
module sparkles.twoslash.completion_icons;

// Ported inline SVGs (fill="currentColor", viewBox 0 0 32 32). method == function.
private enum svgModule = import("icons/completions/module.svg");
private enum svgClass = import("icons/completions/class.svg");
private enum svgMethod = import("icons/completions/method.svg");
private enum svgProperty = import("icons/completions/property.svg");
private enum svgConstructor = import("icons/completions/constructor.svg");
private enum svgInterface = import("icons/completions/interface.svg");
private enum svgFunction = import("icons/completions/function.svg");
private enum svgString = import("icons/completions/string.svg");

// String-imports keep the trailing newline the files end with; trim it once so the
// emitted markup stays tight.
private const(char)[] trimNL(const(char)[] s) @safe pure nothrow @nogc
    => s.length && s[$ - 1] == '\n' ? s[0 .. $ - 1] : s;

/// The reference inline SVG markup for completion `kind` (unknown → `property`).
const(char)[] completionIconSvg(scope const(char)[] kind) @safe pure nothrow @nogc
{
    switch (kind)
    {
        case "module":      return trimNL(svgModule);
        case "class":       return trimNL(svgClass);
        case "method":      return trimNL(svgMethod);
        case "constructor": return trimNL(svgConstructor);
        case "interface":   return trimNL(svgInterface);
        case "function":    return trimNL(svgFunction);
        case "string":      return trimNL(svgString);
        case "property":
        default:            return trimNL(svgProperty);
    }
}

/// A single Unicode glyph for completion `kind` (unknown → `•`).
const(char)[] completionIconGlyph(scope const(char)[] kind) @safe pure nothrow @nogc
{
    switch (kind)
    {
        case "module":      return "◰";
        case "class":       return "◆";
        case "method":
        case "function":    return "ƒ";
        case "constructor": return "⊕";
        case "interface":   return "◇";
        case "string":      return "\"";
        case "property":    return "▪";
        default:            return "•";
    }
}
