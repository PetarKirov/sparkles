/**
The built-in themes, re-exported.

The theme *values* live in $(MREF sparkles,ui,themes) — a theme is an
application's whole design language (syntax rules, semantic slots, chrome
metrics, glyph sets), not a highlighting-only concern, and `sparkles:ui` owns
that vocabulary. What stays here is the highlighting half: `sparkles:syntax`
resolves a theme's rules against a label vocabulary, which the toolkit cannot do
(see $(MREF sparkles,syntax,theme)).

Re-exported rather than moved-and-forgotten so `sparkles.syntax.builtinThemes`
keeps resolving for every consumer.
*/
module sparkles.syntax.themes;

public import sparkles.ui.themes;

@("themes.builtins.resolveCleanly")
unittest
{
    import sparkles.base.term_color : Color;
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
