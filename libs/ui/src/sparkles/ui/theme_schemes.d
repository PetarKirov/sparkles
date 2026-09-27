/**
Which built-in theme is the light or dark sibling of which (`INP22`): what a
theme becomes when the surface switches scheme — a terminal reporting the
change (mode 2031), or an OS appearance.

Data, not a naming convention: the built-ins' names pair up only loosely
(`rose-pine` / `rose-pine-dawn`, `dark-plus` / `light-plus`), and a
three-flavour family (catppuccin's mocha, macchiato and frappe) has one light
sibling for all of them. A theme with no sibling in the set — `tokyo-night`,
`dracula` — stays itself, and says so to whoever asked. Each pair is checked
against the themes' own backgrounds, so the table cannot call a dark theme
light.
*/
module sparkles.ui.theme_schemes;

/// Dark theme → its light sibling, by name. A light theme's dark sibling is
/// the first dark one listed with it.
static immutable string[2][] schemeSiblings = [
    ["github-dark", "github-light"],
    ["github-dark-dimmed", "github-light"],
    ["solarized-dark", "solarized-light"],
    ["catppuccin-mocha", "catppuccin-latte"],
    ["catppuccin-macchiato", "catppuccin-latte"],
    ["catppuccin-frappe", "catppuccin-latte"],
    ["gruvbox-dark-hard", "gruvbox-light-hard"],
    ["ayu-dark", "ayu-light"],
    ["ayu-mirage", "ayu-light"],
    ["rose-pine", "rose-pine-dawn"],
    ["rose-pine-moon", "rose-pine-dawn"],
    ["night-owl", "night-owl-light"],
    ["everforest-dark", "everforest-light"],
    ["min-dark", "min-light"],
    ["material-theme-darker", "material-theme-lighter"],
    ["dark-plus", "light-plus"],
];

/**
The theme to show for `name` — itself `isDark` or not — on a `wantDark` (or
light) surface: `name` when it already matches, else its sibling from
$(LREF schemeSiblings); with no sibling in the set, `name` unchanged and
`unmatched` set, so the caller can say why nothing changed.
*/
string themeForScheme(string name, bool isDark, bool wantDark, out bool unmatched)
    @safe pure nothrow @nogc
{
    if (isDark == wantDark)
        return name;
    foreach (pair; schemeSiblings)
        if (pair[isDark ? 0 : 1] == name)
            return pair[isDark ? 1 : 0];
    unmatched = true;
    return name;
}

@("ui.theme_schemes.pairsAreWhatTheySay")
@safe unittest
{
    import sparkles.base.term_color : Color;
    import sparkles.ui.style : ColorScheme, schemeForBackground;
    import sparkles.ui.themes : builtinThemes;

    // Every pair is a real dark theme and a real light one, by their own
    // backgrounds — the table cannot call a dark theme light.
    foreach (pair; schemeSiblings)
    {
        assert(pair[0] in builtinThemes && pair[1] in builtinThemes, pair[0]);
        const d = builtinThemes[pair[0]].defaultBg, l = builtinThemes[pair[1]].defaultBg;
        assert(d.kind == Color.Kind.rgb && l.kind == Color.Kind.rgb, pair[0]);
        const dark = d.rgb, light = l.rgb;
        assert(schemeForBackground(dark) == ColorScheme.dark, pair[0]);
        assert(schemeForBackground(light) == ColorScheme.light, pair[1]);
    }
}

@("ui.theme_schemes.themeForScheme")
@safe pure nothrow @nogc
unittest
{
    bool unmatched;
    // A dark theme on a light surface becomes its sibling, and back.
    assert(themeForScheme("github-dark", true, false, unmatched) == "github-light" && !unmatched);
    assert(themeForScheme("github-light", false, true, unmatched) == "github-dark" && !unmatched);
    // Already right: itself, whether or not it has a sibling.
    assert(themeForScheme("rose-pine", true, true, unmatched) == "rose-pine" && !unmatched);
    assert(themeForScheme("tokyo-night", true, true, unmatched) == "tokyo-night" && !unmatched);
    // Three dark flavours share one light sibling; the light one's dark
    // sibling is the first listed.
    assert(themeForScheme("catppuccin-frappe", true, false, unmatched) == "catppuccin-latte");
    assert(themeForScheme("catppuccin-latte", false, true, unmatched) == "catppuccin-mocha");
    // No sibling in the set: itself, and the caller is told.
    assert(themeForScheme("tokyo-night", true, false, unmatched) == "tokyo-night" && unmatched);
}
