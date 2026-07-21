#!/usr/bin/env dub
/+ dub.sdl:
    name "download-themes"
    dependency "sparkles:syntax" path="../../.."
    targetPath "build"
+/

module download_themes;

import std.algorithm;
import std.array;
import std.format;
import std.json;
import std.net.curl;
import std.path;
import std.stdio;
import std.string;

import sparkles.syntax.label : standardLabels;

static immutable string[] themesList = [
    "one-dark-pro",
    "dracula",
    "nord",
    "monokai",
    "github-dark",
    "github-light",
    "github-dark-dimmed",
    "tokyo-night",
    "solarized-dark",
    "solarized-light",
    "catppuccin-mocha",
    "catppuccin-macchiato",
    "catppuccin-frappe",
    "catppuccin-latte",
    "gruvbox-dark-hard",
    "gruvbox-light-hard",
    "ayu-dark",
    "ayu-light",
    "ayu-mirage",
    "rose-pine",
    "rose-pine-moon",
    "rose-pine-dawn",
    "night-owl",
    "night-owl-light",
    "everforest-dark",
    "everforest-light",
    "synthwave-84",
    "kanagawa-wave",
    "vesper",
    "poimandres",
    "min-dark",
    "min-light",
    "material-theme-darker",
    "material-theme-lighter",
    "dark-plus",
    "light-plus"
];

struct ScopeMapRule
{
    string prefix;
    string label;
}

static immutable ScopeMapRule[] scopeMappingRules = [
    ScopeMapRule("comment.block.documentation", "comment.documentation"),
    ScopeMapRule("comment.documentation", "comment.documentation"),
    ScopeMapRule("comment.line", "comment.line"),
    ScopeMapRule("comment.block", "comment.block"),
    ScopeMapRule("comment", "comment"),
    ScopeMapRule("punctuation.definition.comment", "comment"),

    ScopeMapRule("string.regexp", "string.regexp"),
    ScopeMapRule("string.quoted", "string"),
    ScopeMapRule("string.special", "string.special"),
    ScopeMapRule("string", "string"),

    ScopeMapRule("constant.character.escape", "constant.character.escape"),
    ScopeMapRule("constant.numeric.float", "constant.numeric.float"),
    ScopeMapRule("constant.numeric.integer", "constant.numeric.integer"),
    ScopeMapRule("constant.numeric", "constant.numeric"),
    ScopeMapRule("constant.language", "constant.builtin"),
    ScopeMapRule("constant.builtin", "constant.builtin"),
    ScopeMapRule("constant", "constant"),

    ScopeMapRule("variable.language", "variable.builtin"),
    ScopeMapRule("variable.parameter", "variable.parameter"),
    ScopeMapRule("variable.other.member", "variable.member"),
    ScopeMapRule("variable.member", "variable.member"),
    ScopeMapRule("variable.other", "variable"),
    ScopeMapRule("variable", "variable"),

    ScopeMapRule("entity.name.function.member", "function.method"),
    ScopeMapRule("entity.name.function", "function"),
    ScopeMapRule("entity.name.method", "function.method"),
    ScopeMapRule("support.function", "function.builtin"),

    ScopeMapRule("entity.name.type.class", "type"),
    ScopeMapRule("entity.name.type", "type"),
    ScopeMapRule("entity.name.class", "type"),
    ScopeMapRule("entity.other.inherited-class", "type"),
    ScopeMapRule("support.type", "type.builtin"),
    ScopeMapRule("support.class", "type"),

    ScopeMapRule("keyword.control", "keyword.control"),
    ScopeMapRule("keyword.operator", "operator"),
    ScopeMapRule("keyword.directive", "keyword.directive"),
    ScopeMapRule("keyword.storage", "keyword.storage"),
    ScopeMapRule("keyword", "keyword"),
    ScopeMapRule("storage.type", "keyword.storage"),
    ScopeMapRule("storage.modifier", "keyword.storage"),
    ScopeMapRule("storage", "keyword.storage"),

    ScopeMapRule("entity.name.tag", "tag"),
    ScopeMapRule("entity.other.attribute-name", "tag.attribute"),
    ScopeMapRule("meta.attribute", "tag.attribute"),
    ScopeMapRule("punctuation.definition.tag", "tag"),

    ScopeMapRule("punctuation.section", "punctuation.bracket"),
    ScopeMapRule("punctuation.definition", "punctuation"),
    ScopeMapRule("punctuation.separator", "punctuation.delimiter"),
    ScopeMapRule("punctuation.terminator", "punctuation.delimiter"),
    ScopeMapRule("punctuation", "punctuation"),

    ScopeMapRule("markup.bold", "markup.bold"),
    ScopeMapRule("markup.heading", "markup.heading"),
    ScopeMapRule("markup.italic", "markup.italic"),
    ScopeMapRule("markup.underline.link", "markup.link.url"),
    ScopeMapRule("markup.list", "markup.list"),
    ScopeMapRule("markup.quote", "markup.quote"),
    ScopeMapRule("markup.raw", "markup.raw"),

    ScopeMapRule("invalid", "error")
];

bool isValidLabel(string label)
{
    import std.range : assumeSorted;
    return assumeSorted(standardLabels).contains(label);
}

string mapScopeToLabel(string scopeName)
{
    scopeName = scopeName.strip();
    if (scopeName.length == 0)
        return null;

    if (isValidLabel(scopeName))
        return scopeName;

    foreach (ref rule; scopeMappingRules)
    {
        if (scopeName == rule.prefix || scopeName.startsWith(rule.prefix ~ "."))
            return rule.label;
    }

    // Fallback: try splitting dotted parts
    auto parts = scopeName.split(".");
    for (size_t i = parts.length; i > 0; i--)
    {
        string candidate = parts[0 .. i].join(".");
        if (isValidLabel(candidate))
            return candidate;
    }

    return null;
}

string cleanHexColor(string c)
{
    if (c.length == 0) return null;
    c = c.strip();
    if (!c.startsWith("#")) return null;

    // Normalize short hex colors:
    if (c.length == 4) // #RGB
    {
        return format("#%c%c%c%c%c%c", c[1], c[1], c[2], c[2], c[3], c[3]);
    }
    else if (c.length == 5) // #RGBA
    {
        return format("#%c%c%c%c%c%c%c%c", c[1], c[1], c[2], c[2], c[3], c[3], c[4], c[4]);
    }

    return c;
}

/// The D expression constructing the `Color` for a cleaned `#RRGGBB` /
/// `#RRGGBBAA` hex string: a `x"…"` hex-string literal through `Color.fromRgb`,
/// with bat's alpha convention (`00` = palette index, `01` = terminal default).
string colorExpr(string cleanHex)
{
    const digits = cleanHex[1 .. $]; // drop the leading '#'
    if (digits.length == 8)
    {
        const alpha = digits[6 .. 8];
        if (alpha == "00")
            return format("Color.fromPalette(0x%s)", digits[0 .. 2]);
        if (alpha == "01")
            return "Color.defaultColor";
    }
    return format("Color.fromRgb(x\"%s\")", digits[0 .. 6]);
}

string parseTextAttr(string styleStr)
{
    if (styleStr.length == 0) return "TextAttr.none";
    auto parts = styleStr.toLower().split();
    string[] flags;
    foreach (p; parts)
    {
        // `underline` is not a TextAttr flag — it is a separate UnderlineStyle
        // field (see hasUnderlineStyle); skip it here.
        if (p == "bold") flags ~= "TextAttr.bold";
        else if (p == "italic") flags ~= "TextAttr.italic";
        else if (p == "strikethrough") flags ~= "TextAttr.strikethrough";
    }
    if (flags.length == 0) return "TextAttr.none";
    // TextAttr's typed `|` keeps the result a TextAttr — no cast needed.
    return flags.join(" | ");
}

/// `true` iff the VS Code fontStyle string requests underline (a separate
/// `UnderlineStyle.single`, not a `TextAttr` flag).
bool hasUnderlineStyle(string styleStr)
{
    import std.algorithm.searching : canFind;

    return styleStr.toLower().split().canFind("underline");
}

string getJsonStringOpt(ref JSONValue json, string[] path)
{
    JSONValue current = json;
    foreach (part; path)
    {
        if (current.type != JSONType.object || part !in current.object)
            return null;
        current = current[part];
    }
    return current.type == JSONType.string ? current.str : null;
}

struct ParsedRule
{
    string label;
    string fg;
    string bg;
    string attrs;
    bool underline;
}

struct ThemeInfo
{
    string name;
    string idName;
    string displayName;
    string defaultFg;
    string defaultBg;
    ParsedRule[] rules;
}

ThemeInfo* processTheme(string themeName)
{
    string url = format("https://raw.githubusercontent.com/shikijs/textmate-grammars-themes/022eed00a8dd29481123f08e1cccf5a5bfee23f9/packages/tm-themes/themes/%s.json", themeName);
    stderr.writef("Downloading %s...\n", themeName);

    string jsonText;
    try
    {
        auto http = HTTP();
        http.setUserAgent("Mozilla/5.0");
        jsonText = cast(string) get(url, http);
    }
    catch (Exception e)
    {
        stderr.writef("Failed to download %s: %s\n", themeName, e.msg);
        return null;
    }

    JSONValue data;
    try
    {
        data = parseJSON(jsonText);
    }
    catch (Exception e)
    {
        stderr.writef("Failed to parse JSON for %s: %s\n", themeName, e.msg);
        return null;
    }

    if (data.type != JSONType.object)
        return null;

    string name = themeName;
    if (auto nameOpt = "name" in data.object)
        if (nameOpt.type == JSONType.string)
            name = nameOpt.str;

    string defaultFg, defaultBg;
    if (auto colorsOpt = "colors" in data.object)
    {
        if (colorsOpt.type == JSONType.object)
        {
            defaultFg = cleanHexColor(getJsonStringOpt(*colorsOpt, ["editor.foreground"]));
            defaultBg = cleanHexColor(getJsonStringOpt(*colorsOpt, ["editor.background"]));
        }
    }

    ParsedRule[] rules;
    bool[string] seen;

    if (auto tokenColorsVal = "tokenColors" in data.object)
    {
        if (tokenColorsVal.type == JSONType.array)
        {
            foreach (ref tc; tokenColorsVal.array)
            {
                if (tc.type != JSONType.object) continue;
                auto settingsOpt = "settings" in tc.object;
                if (!settingsOpt || settingsOpt.type != JSONType.object) continue;

                string fg = cleanHexColor(getJsonStringOpt(*settingsOpt, ["foreground"]));
                string bg = cleanHexColor(getJsonStringOpt(*settingsOpt, ["background"]));
                string fontStyle = getJsonStringOpt(*settingsOpt, ["fontStyle"]);
                string attrs = parseTextAttr(fontStyle);
                bool underline = hasUnderlineStyle(fontStyle);

                if (!fg && !bg && attrs == "TextAttr.none" && !underline) continue;

                if (auto scopeOpt = "scope" in tc.object)
                {
                    string[] scopes;
                    if (scopeOpt.type == JSONType.string)
                    {
                        scopes = scopeOpt.str.split(",");
                    }
                    else if (scopeOpt.type == JSONType.array)
                    {
                        foreach (ref s; scopeOpt.array)
                            if (s.type == JSONType.string)
                                scopes ~= s.str;
                    }

                    foreach (scopeStr; scopes)
                    {
                        foreach (s; scopeStr.split(","))
                        {
                            string label = mapScopeToLabel(s);
                            if (label)
                            {
                                string key = format("%s|%s|%s|%s|%s", label, fg, bg, attrs, underline);
                                if (key !in seen)
                                {
                                    seen[key] = true;
                                    rules ~= ParsedRule(label, fg, bg, attrs, underline);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    auto info = new ThemeInfo();
    info.name = name;
    info.idName = themeName.replace("-", "_");
    info.displayName = name;
    info.defaultFg = defaultFg;
    info.defaultBg = defaultBg;
    info.rules = rules;
    return info;
}

void main()
{
    ThemeInfo*[] results;
    foreach (t; themesList)
    {
        if (auto res = processTheme(t))
            results ~= res;
    }

    string dCode = `/**
Built-in themes.

This file is automatically generated. It includes 30+ popular themes
derived from Shikijs/TextMate themes.
*/
module sparkles.syntax.themes;

import sparkles.syntax.color : Color;
import sparkles.syntax.theme : StyleSpec, TextAttr, Theme, ThemeRule, UnderlineStyle;

@safe:

/// Alias definitions for backward compatibility:
static immutable Theme builtinDark = catppuccin_mocha;
static immutable Theme builtinLight = solarized_light;
`;

    foreach (theme; results)
    {
        dCode ~= format("\n/// %s Theme.\n", theme.displayName);
        dCode ~= format("static immutable Theme %s = Theme(\n", theme.idName);
        dCode ~= format("    name: \"%s\",\n", theme.name);
        if (theme.defaultFg)
            dCode ~= format("    defaultFg: %s,\n", colorExpr(theme.defaultFg));
        if (theme.defaultBg)
            dCode ~= format("    defaultBg: %s,\n", colorExpr(theme.defaultBg));
        dCode ~= "    rules: [\n";
        foreach (ref r; theme.rules)
        {
            string[] styleArgs;
            if (r.fg)
                styleArgs ~= format("fg: %s", colorExpr(r.fg));
            if (r.bg)
                styleArgs ~= format("bg: %s", colorExpr(r.bg));
            if (r.attrs != "TextAttr.none")
                styleArgs ~= format("attrs: %s", r.attrs);
            if (r.underline)
                styleArgs ~= "underline: UnderlineStyle.single";

            string styleStr = styleArgs.length ? format("StyleSpec(%s)", styleArgs.join(", ")) : "StyleSpec.init";
            dCode ~= format("        ThemeRule(\"%s\", %s),\n", r.label, styleStr);
        }
        dCode ~= format("    ]);\n");
    }

    dCode ~= q"EOF
/// Dictionary of all built-in themes by name (static AA literal — no ctor).
static immutable Theme[string] builtinThemes = [
EOF";

    // Emit each distinct key once: a single-word theme name and its
    // hyphen-stripped alias collide, and an AA literal has no last-wins.
    bool[string] keysSeen;
    foreach (theme; results)
    {
        const simplified = theme.name.toLower().replace(" ", "").replace("-", "");
        foreach (key; [theme.name, simplified])
        {
            if (key in keysSeen)
                continue;
            keysSeen[key] = true;
            dCode ~= format("    \"%s\": %s,\n", key, theme.idName);
        }
    }

    dCode ~= q"EOF
];

@("themes.builtins.resolveCleanly")
unittest
{
    import sparkles.syntax.event : LabelId;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.theme : resolveTheme;

    const labels = LabelSet.standard();
    foreach (theme; builtinThemes.values)
    {
        const resolved = resolveTheme(theme, labels);
        // Ensure standard theme elements resolve
        assert(!resolved[LabelId.none].fg.isSet || resolved[LabelId.none].fg.kind != Color.Kind.unset);
    }
}
EOF";

    import std.file : write;
    string targetPath = "/home/petar/code/repos/mine/sparkles-syntax/libs/syntax/src/sparkles/syntax/themes.d";
    try
    {
        write(targetPath, dCode);
        writefln("Themes generated successfully in %s", targetPath);
    }
    catch (Exception e)
    {
        stderr.writef("Failed to write to %s: %s\n", targetPath, e.msg);
    }
}
