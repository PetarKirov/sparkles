/**
Built-in themes.

Two `static immutable` $(REF Theme, sparkles,syntax,theme) values, authored
as plain data over the canonical label vocabulary:

$(LIST
    * $(LREF builtinDark) — palette derived from
        $(LINK2 https://github.com/catppuccin/catppuccin, Catppuccin Mocha)
        (MIT License, © Catppuccin Org);
    * $(LREF builtinLight) — palette derived from
        $(LINK2 https://ethanschoonover.com/solarized/, Solarized Light)
        (MIT License, © Ethan Schoonover).
)

Only the color values derive from those palettes; the selector → color
mapping is original to this module. Theme files (TOML/JSON) are a future
seam — these exist so the library colors something out of the box.
*/
module sparkles.syntax.themes;

import sparkles.syntax.color : Color, parseHexColor;
import sparkles.syntax.theme : FontStyle, StyleSpec, Theme, ThemeRule;

@safe:

/// Dark built-in theme (Catppuccin-Mocha-derived palette).
static immutable Theme builtinDark = Theme(
    name: "sparkles-dark",
    defaultFg: hex("#cdd6f4"), // text
    defaultBg: hex("#1e1e2e"), // base
    rules: [
        ThemeRule("attribute", fg("#f9e2af")),
        ThemeRule("boolean", fg("#fab387")),
        ThemeRule("comment", style("#6c7086", FontStyle.italic)),
        ThemeRule("constant", fg("#fab387")),
        ThemeRule("constant.character.escape", fg("#f5c2e7")),
        ThemeRule("constructor", fg("#74c7ec")),
        ThemeRule("diff.delta", fg("#89b4fa")),
        ThemeRule("diff.minus", fg("#f38ba8")),
        ThemeRule("diff.plus", fg("#a6e3a1")),
        ThemeRule("error", fg("#f38ba8")),
        ThemeRule("escape", fg("#f5c2e7")),
        ThemeRule("function", fg("#89b4fa")),
        ThemeRule("function.macro", fg("#94e2d5")),
        ThemeRule("keyword", fg("#cba6f7")),
        ThemeRule("label", fg("#74c7ec")),
        ThemeRule("markup.bold", style(null, FontStyle.bold)),
        ThemeRule("markup.heading", style("#89b4fa", FontStyle.bold)),
        ThemeRule("markup.italic", style(null, FontStyle.italic)),
        ThemeRule("markup.link", fg("#74c7ec")),
        ThemeRule("markup.link.url", style("#74c7ec", FontStyle.underline)),
        ThemeRule("markup.list", fg("#cba6f7")),
        ThemeRule("markup.quote", fg("#a6adc8")),
        ThemeRule("markup.raw", fg("#a6e3a1")),
        ThemeRule("markup.strikethrough", style(null, FontStyle.strikethrough)),
        ThemeRule("module", style("#b4befe", FontStyle.italic)),
        ThemeRule("namespace", style("#b4befe", FontStyle.italic)),
        ThemeRule("number", fg("#fab387")),
        ThemeRule("operator", fg("#89dceb")),
        ThemeRule("property", fg("#b4befe")),
        ThemeRule("punctuation", fg("#9399b2")),
        ThemeRule("string", fg("#a6e3a1")),
        ThemeRule("string.regexp", fg("#f5c2e7")),
        ThemeRule("string.special", fg("#f5c2e7")),
        ThemeRule("string.special.url", style("#89dceb", FontStyle.underline)),
        ThemeRule("tag", fg("#cba6f7")),
        ThemeRule("tag.attribute", fg("#f9e2af")),
        ThemeRule("type", fg("#f9e2af")),
        ThemeRule("type.builtin", style("#f9e2af", FontStyle.italic)),
        ThemeRule("variable", fg("#cdd6f4")),
        ThemeRule("variable.builtin", fg("#f38ba8")),
        ThemeRule("variable.member", fg("#b4befe")),
        ThemeRule("variable.other.member", fg("#b4befe")),
        ThemeRule("variable.parameter", style("#eba0ac", FontStyle.italic)),
    ]);

/// Light built-in theme (Solarized-Light-derived palette).
static immutable Theme builtinLight = Theme(
    name: "sparkles-light",
    defaultFg: hex("#657b83"), // base00
    defaultBg: hex("#fdf6e3"), // base3
    rules: [
        ThemeRule("attribute", fg("#b58900")),
        ThemeRule("boolean", fg("#2aa198")),
        ThemeRule("comment", style("#93a1a1", FontStyle.italic)),
        ThemeRule("constant", fg("#2aa198")),
        ThemeRule("constant.character.escape", fg("#cb4b16")),
        ThemeRule("constructor", fg("#268bd2")),
        ThemeRule("diff.delta", fg("#b58900")),
        ThemeRule("diff.minus", fg("#dc322f")),
        ThemeRule("diff.plus", fg("#859900")),
        ThemeRule("error", fg("#dc322f")),
        ThemeRule("escape", fg("#cb4b16")),
        ThemeRule("function", fg("#268bd2")),
        ThemeRule("keyword", fg("#859900")),
        ThemeRule("keyword.directive", fg("#cb4b16")),
        ThemeRule("label", fg("#6c71c4")),
        ThemeRule("markup.bold", style(null, FontStyle.bold)),
        ThemeRule("markup.heading", style("#cb4b16", FontStyle.bold)),
        ThemeRule("markup.italic", style(null, FontStyle.italic)),
        ThemeRule("markup.link", fg("#268bd2")),
        ThemeRule("markup.link.url", style("#268bd2", FontStyle.underline)),
        ThemeRule("markup.quote", fg("#93a1a1")),
        ThemeRule("markup.raw", fg("#2aa198")),
        ThemeRule("markup.strikethrough", style(null, FontStyle.strikethrough)),
        ThemeRule("module", style("#6c71c4", FontStyle.italic)),
        ThemeRule("namespace", style("#6c71c4", FontStyle.italic)),
        ThemeRule("number", fg("#2aa198")),
        ThemeRule("operator", fg("#859900")),
        ThemeRule("property", fg("#268bd2")),
        ThemeRule("string", fg("#2aa198")),
        ThemeRule("string.regexp", fg("#d33682")),
        ThemeRule("string.special", fg("#cb4b16")),
        ThemeRule("tag", fg("#268bd2")),
        ThemeRule("type", fg("#b58900")),
        ThemeRule("type.builtin", style("#b58900", FontStyle.italic)),
        ThemeRule("variable.builtin", fg("#cb4b16")),
        ThemeRule("variable.parameter", style("#6c71c4", FontStyle.italic)),
    ]);

@("themes.builtins.resolveCleanly")
unittest
{
    import sparkles.syntax.event : LabelId;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;

    const labels = LabelSet.standard();
    foreach (theme; [builtinDark, builtinLight])
    {
        const resolved = resolveTheme(theme, labels);
        assert(resolved[labels.find("keyword")].fg.kind == Color.Kind.rgb);
        assert(resolved[labels.find("comment")].font == FontStyle.italic);
        // deep labels inherit via longest prefix
        assert(!resolved[labels.find("string.special.key")].empty);
    }
    // every rule selector must resolve to a vocabulary label (no dead rules)
    foreach (theme; [builtinDark, builtinLight])
        foreach (rule; theme.rules)
            assert(labels.find(rule.selector) != LabelId.none, rule.selector);
}

/// CTFE `#RRGGBB` → `Color` for theme data.
private Color hex(string s) pure nothrow @nogc
{
    const(char)[] t = s;
    auto parsed = parseHexColor(t);
    assert(parsed.hasValue && t.length == 0, "invalid theme hex color");
    return parsed.value;
}

private StyleSpec fg(string hexColor) pure nothrow @nogc
    => StyleSpec(fg: hex(hexColor));

private StyleSpec style(string hexColor, FontStyle font) pure nothrow @nogc
    => StyleSpec(fg: hexColor is null ? Color.init : hex(hexColor), font: font);
