/**
Built-in syntax highlighting theme defaults.
*/
module sparkles.syntax.themes;

import sparkles.base.term_color : Color;
import sparkles.syntax.theme : StyleSpec, SyntaxTheme, TextAttr, ThemeRule;

@safe:

/// Default dark syntax theme (Catppuccin Mocha palette).
static immutable SyntaxTheme builtinDark = SyntaxTheme(
    name: "catppuccin-mocha",
    defaultFg: Color.fromRgb(x"cdd6f4"),
    defaultBg: Color.fromRgb(x"1e1e2e"),
    rules: [
        ThemeRule("variable", StyleSpec(fg: Color.fromRgb(x"eba0ac"), attrs: TextAttr.italic)),
        ThemeRule("punctuation", StyleSpec(fg: Color.fromRgb(x"9399b2"))),
        ThemeRule("comment", StyleSpec(fg: Color.fromRgb(x"9399b2"), attrs: TextAttr.italic)),
        ThemeRule("string", StyleSpec(fg: Color.fromRgb(x"a6e3a1"))),
        ThemeRule("constant.character.escape", StyleSpec(fg: Color.fromRgb(x"f5c2e7"))),
        ThemeRule("constant.numeric", StyleSpec(fg: Color.fromRgb(x"fab387"))),
        ThemeRule("constant.builtin.boolean", StyleSpec(fg: Color.fromRgb(x"fab387"))),
        ThemeRule("constant.builtin", StyleSpec(fg: Color.fromRgb(x"f38ba8"))),
        ThemeRule("keyword", StyleSpec(fg: Color.fromRgb(x"cba6f7"))),
        ThemeRule("operator", StyleSpec(fg: Color.fromRgb(x"cba6f7"), attrs: TextAttr.bold)),
        ThemeRule("variable.builtin", StyleSpec(fg: Color.fromRgb(x"f5c2e7"))),
        ThemeRule("type.builtin", StyleSpec(fg: Color.fromRgb(x"f9e2af"), attrs: TextAttr.italic)),
        ThemeRule("keyword.storage", StyleSpec(fg: Color.fromRgb(x"cba6f7"))),
        ThemeRule("tag", StyleSpec(fg: Color.fromRgb(x"89b4fa"))),
        ThemeRule("keyword.operator", StyleSpec(fg: Color.fromRgb(x"94e2d5"))),
        ThemeRule("function", StyleSpec(fg: Color.fromRgb(x"89b4fa"), attrs: TextAttr.italic)),
        ThemeRule("function.builtin", StyleSpec(fg: Color.fromRgb(x"89b4fa"), attrs: TextAttr.italic)),
        ThemeRule("type", StyleSpec(fg: Color.fromRgb(x"f9e2af"), attrs: TextAttr.italic)),
        ThemeRule("variable.parameter", StyleSpec(fg: Color.fromRgb(x"eba0ac"), attrs: TextAttr.italic)),
        ThemeRule("tag.attribute", StyleSpec(fg: Color.fromRgb(x"f9e2af"), attrs: TextAttr.italic)),
        ThemeRule("keyword.directive", StyleSpec(fg: Color.fromRgb(x"f9e2af"))),
        ThemeRule("module", StyleSpec(fg: Color.fromRgb(x"f9e2af"))),
        ThemeRule("string.special.key", StyleSpec(fg: Color.fromRgb(x"f9e2af"))),
        ThemeRule("comment.documentation", StyleSpec(fg: Color.fromRgb(x"cdd6f4"))),
        ThemeRule("constant", StyleSpec(fg: Color.fromRgb(x"fab387"))),
        ThemeRule("diff.delta", StyleSpec(fg: Color.fromRgb(x"fab387"))),
        ThemeRule("diff.plus", StyleSpec(fg: Color.fromRgb(x"a6e3a1"))),
        ThemeRule("diff.minus", StyleSpec(fg: Color.fromRgb(x"f38ba8"))),
        ThemeRule("comment.block", StyleSpec(fg: Color.fromRgb(x"eba0ac"))),
        ThemeRule("keyword.function", StyleSpec(fg: Color.fromRgb(x"cba6f7"))),
        ThemeRule("string.special.symbol", StyleSpec(fg: Color.fromRgb(x"eba0ac"))),
        ThemeRule("comment.line", StyleSpec(fg: Color.fromRgb(x"f5c2e7"), attrs: TextAttr.italic)),
        ThemeRule("markup.heading", StyleSpec(fg: Color.fromRgb(x"f38ba8"), attrs: TextAttr.bold)),
        ThemeRule("markup.bold", StyleSpec(fg: Color.fromRgb(x"f38ba8"), attrs: TextAttr.bold)),
        ThemeRule("markup.italic", StyleSpec(fg: Color.fromRgb(x"f38ba8"), attrs: TextAttr.italic)),
        ThemeRule("markup.strikethrough", StyleSpec(fg: Color.fromRgb(x"a6adc8"), attrs: TextAttr.strikethrough)),
        ThemeRule("markup.link.url", StyleSpec(fg: Color.fromRgb(x"89b4fa"))),
        ThemeRule("string.special.url", StyleSpec(fg: Color.fromRgb(x"b4befe"))),
        ThemeRule("markup.link", StyleSpec(fg: Color.fromRgb(x"b4befe"))),
        ThemeRule("markup.raw", StyleSpec(fg: Color.fromRgb(x"a6e3a1"))),
        ThemeRule("markup.quote", StyleSpec(fg: Color.fromRgb(x"f5c2e7"))),
        ThemeRule("markup.list", StyleSpec(fg: Color.fromRgb(x"94e2d5"))),
    ]);

/// Default light syntax theme (Solarized Light palette).
static immutable SyntaxTheme builtinLight = SyntaxTheme(
    name: "solarized-light",
    defaultFg: Color.fromRgb(x"657B83"),
    defaultBg: Color.fromRgb(x"FDF6E3"),
    rules: [
        ThemeRule("embedded", StyleSpec(fg: Color.fromRgb(x"657B83"))),
        ThemeRule("variable", StyleSpec(fg: Color.fromRgb(x"268BD2"))),
        ThemeRule("comment", StyleSpec(fg: Color.fromRgb(x"93A1A1"), attrs: TextAttr.italic)),
        ThemeRule("string", StyleSpec(fg: Color.fromRgb(x"2AA198"))),
        ThemeRule("string.regexp", StyleSpec(fg: Color.fromRgb(x"DC322F"))),
        ThemeRule("constant.numeric", StyleSpec(fg: Color.fromRgb(x"D33682"))),
        ThemeRule("variable.builtin", StyleSpec(fg: Color.fromRgb(x"268BD2"))),
        ThemeRule("keyword", StyleSpec(fg: Color.fromRgb(x"859900"))),
        ThemeRule("keyword.storage", StyleSpec(fg: Color.fromRgb(x"586E75"), attrs: TextAttr.bold)),
        ThemeRule("type", StyleSpec(fg: Color.fromRgb(x"859900"))),
        ThemeRule("module", StyleSpec(fg: Color.fromRgb(x"CB4B16"))),
        ThemeRule("function", StyleSpec(fg: Color.fromRgb(x"268BD2"))),
        ThemeRule("constant.builtin", StyleSpec(fg: Color.fromRgb(x"B58900"))),
        ThemeRule("keyword.directive", StyleSpec(fg: Color.fromRgb(x"B58900"))),
        ThemeRule("function.builtin", StyleSpec(fg: Color.fromRgb(x"268BD2"))),
        ThemeRule("constant.character", StyleSpec(fg: Color.fromRgb(x"CB4B16"))),
        ThemeRule("constant", StyleSpec(fg: Color.fromRgb(x"CB4B16"))),
        ThemeRule("tag", StyleSpec(fg: Color.fromRgb(x"93A1A1"))),
        ThemeRule("tag.attribute", StyleSpec(fg: Color.fromRgb(x"93A1A1"))),
        ThemeRule("type.builtin", StyleSpec(fg: Color.fromRgb(x"859900"))),
        ThemeRule("error", StyleSpec(fg: Color.fromRgb(x"DC322F"))),
        ThemeRule("diff.minus", StyleSpec(fg: Color.fromRgb(x"DC322F"))),
        ThemeRule("diff.delta", StyleSpec(fg: Color.fromRgb(x"CB4B16"))),
        ThemeRule("diff.plus", StyleSpec(fg: Color.fromRgb(x"859900"))),
        ThemeRule("markup.quote", StyleSpec(fg: Color.fromRgb(x"859900"))),
        ThemeRule("markup.list", StyleSpec(fg: Color.fromRgb(x"B58900"))),
        ThemeRule("markup.bold", StyleSpec(fg: Color.fromRgb(x"D33682"), attrs: TextAttr.bold)),
        ThemeRule("markup.italic", StyleSpec(fg: Color.fromRgb(x"D33682"), attrs: TextAttr.italic)),
        ThemeRule("markup.strikethrough", StyleSpec(attrs: TextAttr.strikethrough)),
        ThemeRule("markup.heading", StyleSpec(fg: Color.fromRgb(x"268BD2"), attrs: TextAttr.bold)),
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
        assert(resolved[LabelId.none].fg.kind != Color.Kind.unset);
    }
}
