/**
A theme as CSS custom properties (design-system `WEB1`).

Every token of a theme file becomes one property named from its path: `--spk-`
then the path with `.` replaced by `-`, so `text.muted.fg` is
`--spk-text-muted-fg` and `scrollbar.thumb.hover.bg` is
`--spk-scrollbar-thumb-hover-bg`. The name is computable from the file alone,
and a state sits before the channel exactly as it does in the file (D60).

A component's stylesheet reads a state with the rest value as its fallback —
`var(--spk-x-hover-fg, var(--spk-x-fg))` — so a state a theme leaves unset
falls through as `TOK4` requires. Nothing here writes a selector for a state:
states are properties, not rules (OQ4, D60).

$(LREF writeThemeProperties) writes the declarations for one theme; the
stylesheet around them (light, dark, scopes) is the caller's, as
`sparkles.docs.assets` composes it.
*/
module sparkles.ui.css;

import std.algorithm.sorting : sort;
import std.array : appender;
import std.conv : text;
import std.format : format;
import std.math : round;
import std.range.primitives : put;

import sparkles.base.text.writers : formatted;

import sparkles.ui.dtcg : aliasTarget, collectTokens, DtcgJson, DtcgResult, writeNumber,
    parseColor, parseDimension;
import sparkles.ui.theme : Theme;
import sparkles.ui.theme_file : exportTheme, overlay, ThemeFile;

/// Writes the custom-property name of the token at `path` (`WEB1`).
void writeCssPropertyName(W)(ref W w, scope const(char)[] path)
{
    put(w, "--spk-");
    foreach (c; path)
        put(w, c == '.' ? '-' : c);
}

///
@("ui.css.writeCssPropertyName.isThePathDashed")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref w) => writeCssPropertyName(w, "text.muted.fg"))("--spk-text-muted-fg");
    checkWriter!((ref w) => writeCssPropertyName(w, "scrollbar.thumb.hover.bg"))
        ("--spk-scrollbar-thumb-hover-bg");
    checkWriter!((ref w) => writeCssPropertyName(w, "page.bg"))("--spk-page-bg");
}

/**
Writes one `--spk-*: value;` declaration per token of `t`, sorted by path,
each on its own line after `indent`. Colors are `#rrggbb`, or `rgb(r g b / a)`
when translucent; dimensions keep their unit; plain numbers (cell metrics,
percentages) stay unitless for the reading rule to scale; an alias is a
`var()` of its target. A derived palette is resolved, so every slot has its
values, not only the ones the theme pins.
*/
void writeThemeProperties(W)(ref W w, const Theme t, string indent = "  ")
    => writeDocumentProperties(w, exportTheme(t, resolvedPalette: true), indent);

/**
ditto, for a loaded theme file: its theme's tokens, with the file's own tokens
over them — its aliases stay `var()`s, and tokens the theme does not map (a
site's own primitives, such as a gradient's stops) reach CSS too.
*/
void writeThemeProperties(W)(ref W w, const ThemeFile f, string indent = "  ")
    => writeDocumentProperties(w,
        overlay(exportTheme(f.theme, resolvedPalette: true), f.document), indent);

private void writeDocumentProperties(W)(ref W w, const DtcgJson doc, string indent)
{
    auto tokens = collectTokens(doc);
    assert(tokens.hasValue, "an exported theme is a valid document");
    string[] paths;
    foreach (ref tok; tokens.value.tokens)
        paths ~= tok.path;
    paths.sort();
    foreach (path; paths)
    {
        const tok = path in tokens.value;
        if (auto target = aliasTarget(tok.value))
        {
            // An alias stays a reference, so the relation holds in CSS too. A
            // state aliased to a channel its target leaves unset takes
            // nothing from it (`TOK4`), and is not written.
            if (target.pointer || (target.text in tokens.value) is null)
                continue;
            put(w, indent);
            writeCssPropertyName(w, path);
            put(w, ": var(");
            writeCssPropertyName(w, target.text);
            put(w, ");\n");
            continue;
        }
        auto value = tokens.value.resolved(path);
        assert(value.hasValue, path);
        const css = cssValue(tok.type, value.value, path);
        if (css.length == 0)
            continue;
        put(w, indent);
        writeCssPropertyName(w, path);
        put(w, ": ");
        put(w, css);
        put(w, ";\n");
    }
}

/// A resolved token value as CSS, or `null` for a type CSS has no value for.
private string cssValue(string type, const DtcgJson v, string path) @safe
{
    switch (type)
    {
        case "color":
            const c = parseColor(v, path);
            if (c.hasError)
                return null;
            const rgb = c.value.rgb;
            return c.value.alpha == 0xFF
                ? format("#%02x%02x%02x", rgb.r, rgb.g, rgb.b)
                : format("rgb(%d %d %d / %s)", rgb.r, rgb.g, rgb.b,
                    formatted!writeNumber(round(c.value.alpha / 255.0 * 1e4) / 1e4));
        case "dimension":
            const d = parseDimension(v, path);
            return d.hasError ? null : text(i"$(formatted!writeNumber(d.value.value))$(d.value.unit)");
        case "number":
            return v.kind == DtcgJson.Kind.number ? v.text : null;
        case "fontFamily":
            return fontStack(v);
        default:
            return null;
    }
}

/// A `fontFamily` value as a `font-family` stack: names quoted, the CSS
/// generic families (`monospace`, `ui-sans-serif`, …) bare.
private string fontStack(const DtcgJson v) @safe
{
    import std.algorithm.comparison : among;

    string one(string name)
        => name.among("serif", "sans-serif", "monospace", "cursive", "fantasy",
            "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded",
            "math", "emoji", "fangsong")
            ? name : "'" ~ name ~ "'";
    if (v.isString)
        return one(v.text);
    if (v.kind != DtcgJson.Kind.array)
        return null;
    string s;
    foreach (i, ref item; v.items)
    {
        if (!item.isString)
            return null;
        s ~= (i ? ", " : "") ~ one(item.text);
    }
    return s;
}

@("ui.css.writeThemeProperties.everySlotAndTheSyntax")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.themes : builtinThemes;

    const css = formatted!writeThemeProperties(builtinThemes["one-dark-pro"]).toString;
    // The palette is derived, yet every slot has its values.
    assert(css.canFind("  --spk-text-muted-fg: #"), css);
    assert(css.canFind("  --spk-scrollbar-thumb-fg: #"), css);
    assert(css.canFind("  --spk-page-bg: #"), css);
    assert(css.canFind("  --spk-syntax-keyword-fg: #"), css);
    // Cell metrics stay unitless; px dimensions keep their unit.
    assert(css.canFind("  --spk-overlay-pad-inline: "), css);
}

@("ui.css.writeThemeProperties.slotNamesAndAliases")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.term_color : Color;
    import sparkles.ui.style : InteractionState, Slot;
    import sparkles.ui.themes : builtinThemes;
    import std.conv : text;
    import sparkles.base.text.writers : formatted;
    import sparkles.ui.tokens : ColorChannel, writeCssName;

    const t = builtinThemes["one-dark-pro"];
    const css = formatted!writeThemeProperties(t).toString;
    // The slot form of the name and the path form agree, for every set leaf.
    const p = t.effectivePalette;
    foreach (i; 0 .. Slot.max + 1)
    {
        if (p.fg[i].kind == Color.Kind.rgb)
            assert(css.canFind(text(i"  $(formatted!writeCssName(cast(Slot) i, ColorChannel.foreground)): ")),
                formatted!writeCssName(cast(Slot) i, ColorChannel.foreground).toString);
        if (p.bg[i].kind == Color.Kind.rgb)
            assert(css.canFind(text(i"  $(formatted!writeCssName(cast(Slot) i, ColorChannel.background)): ")),
                formatted!writeCssName(cast(Slot) i, ColorChannel.background).toString);
    }
    // A state aliased to another slot stays a reference to it.
    assert(css.canFind(text(i"$(formatted!writeCssName(Slot.inherit, ColorChannel.background,
        InteractionState.selected)): var($(formatted!writeCssName(Slot.selection,
        ColorChannel.background)));\n")), css);
}

@("ui.css.writeThemeProperties.aFilesOwnTokensAndAliases")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.theme_file : loadTheme;

    auto f = loadTheme(`{
        "palette": { "$type": "color", "indigo": { "$value": "#6366f1" } },
        "accent": { "primary": { "fg": { "$value": "{palette.indigo}" } } }
    }`);
    assert(f.hasValue, f.error.message);
    auto w = appender!string;
    writeThemeProperties(w, f.value);
    const css = w[];
    // The primitive the theme does not map still reaches CSS, and the slot
    // stays a reference to it.
    assert(css.canFind("  --spk-palette-indigo: #6366f1;\n"), css);
    assert(css.canFind("  --spk-accent-primary-fg: var(--spk-palette-indigo);\n"), css);
    // Everything else is the theme's, derived as usual.
    assert(css.canFind("  --spk-text-muted-fg: #"), css);
}

@("ui.css.writeThemeProperties.fontFacesAndRoles")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.theme : FontFace, FontRole;

    Theme t = Theme(name: "typed");
    t.fonts.faces[FontFace.sans] = ["Inter", "sans-serif"];
    const css = formatted!writeThemeProperties(t).toString;
    assert(css.canFind("  --spk-font-family-sans: 'Inter', sans-serif;\n"), css);
    // A role is a reference to its face, so retargeting it is one line.
    assert(css.canFind("  --spk-font-body: var(--spk-font-family-sans);\n"), css);
    // A role whose face is empty is the target's default: nothing emitted.
    assert(!css.canFind("--spk-font-code"), css);
}

@("ui.css.fontStack.quotesNamesNotGenerics")
@safe unittest
{
    const v = DtcgJson.array([DtcgJson.str("Fira Code"), DtcgJson.str("ui-monospace"),
        DtcgJson.str("monospace")]);
    assert(fontStack(v) == "'Fira Code', ui-monospace, monospace");
    assert(fontStack(DtcgJson.str("Inter")) == "'Inter'");
}
