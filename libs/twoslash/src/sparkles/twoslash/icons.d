/**
Completion-kind and custom-tag icons for the HTML overlay — the glyphs
`@shikijs/twoslash`'s `rendererRich` draws before each completion candidate
(`twoslash-completions-icon`) and on each `// @tag` line (`twoslash-tag-icon`).

Two built-in strategies (chosen via
$(REF TwoslashHtmlOptions, sparkles,twoslash,render_html)'s `completionIcons` /
`tagIcons`):

$(LIST
    * $(B svg) — the reference inline SVGs, ported verbatim from Shiki's
        `icons-completions.json` / `icons-tags.json` and string-imported from
        `views/icons/{completions,tags}/*.svg`. Self-contained (each path is
        `fill="currentColor"`; sized by the stylesheet), so they inherit the
        theme's text color with no external assets.
    * $(B glyph) — a single Unicode glyph per kind, for minimal output.
)

An unknown completion kind falls back to `property` (svg) / `•` (glyph); an
unknown tag falls back to `annotate` / `#`.
*/
module sparkles.twoslash.icons;

// Ported completion-kind SVGs (fill="currentColor", viewBox 0 0 32 32).
// method == function.
private enum svgModule = import("icons/completions/module.svg");
private enum svgClass = import("icons/completions/class.svg");
private enum svgMethod = import("icons/completions/method.svg");
private enum svgProperty = import("icons/completions/property.svg");
private enum svgConstructor = import("icons/completions/constructor.svg");
private enum svgInterface = import("icons/completions/interface.svg");
private enum svgFunction = import("icons/completions/function.svg");
private enum svgString = import("icons/completions/string.svg");

// Ported custom-tag SVGs.
private enum svgTagLog = import("icons/tags/log.svg");
private enum svgTagError = import("icons/tags/error.svg");
private enum svgTagWarn = import("icons/tags/warn.svg");
private enum svgTagAnnotate = import("icons/tags/annotate.svg");

// String-imports keep the trailing newline the files end with; trim it once so
// the emitted markup stays tight.
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

/// The reference inline SVG markup for custom-tag `name` (unknown → `annotate`).
const(char)[] tagIconSvg(scope const(char)[] name) @safe pure nothrow @nogc
{
    switch (name)
    {
        case "log":   return trimNL(svgTagLog);
        case "error": return trimNL(svgTagError);
        case "warn":  return trimNL(svgTagWarn);
        case "annotate":
        default:      return trimNL(svgTagAnnotate);
    }
}

/// A single Unicode glyph for custom-tag `name` (unknown → `#`).
const(char)[] tagIconGlyph(scope const(char)[] name) @safe pure nothrow @nogc
{
    switch (name)
    {
        case "log":   return "≡";
        case "error": return "✕";
        case "warn":  return "⚠";
        case "annotate": return "✎";
        default:      return "#";
    }
}
