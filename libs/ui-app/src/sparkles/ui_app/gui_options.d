/**
The window and font command line, declared once (`CLI1`–`CLI3`).

Both existing applications grew the same flags independently — `--font`,
`--font-size`, `--window-width`, `--font-dir`, `--font-codepoint-map` — with
different help text, different resolution order, and different defaults for the
same setting. Nothing made them disagree on purpose; there was simply no one
place to put them.

$(B The fields live in a mixin, and the struct is defined by it.) Two parallel
declarations of one vocabulary is the defect being removed, so this module does
not contain a second copy that could drift from the first: $(LREF GuiOptions) is
`mixin GuiCliFields` and nothing else. An application either embeds that struct
or mixes the fields into its own parameter type, so an application whose flags
are flat stays flat.
*/
module sparkles.ui_app.gui_options;

import sparkles.core_cli.args : CliOption;
import sparkles.ui.theme : Theme;

/**
The default `--font`: a fontconfig preference list, first installed family wins.

$(B Maple Mono NF CN leads because it is the family this repository actually
ships.) `nix build .#sparkles-fonts` bundles it with all four styled faces and
`fc-query` charset sidecars, and the Android build already made it primary by
prepending it to this list — so every target carrying a font bundle now resolves
to the same family, and the desktop no longer differs from the phone by accident.

Nerd-Font variants follow for the reason they used to lead: a decorated document
view draws its icons from them — heading marks, callouts, checkboxes — and with a
non-Nerd font those degrade to tofu rather than to something plainer. The list
ends in the generic `monospace`, so a machine with none of the named families
still renders.

$(B The name is exact and not abbreviatable.) fontconfig matches
`Maple Mono NF CN`; `Maple Mono` and `Maple Mono NF` fall through to an
unrelated proportional face, so a shortened spelling here would silently pass
the bundled font by.

Moved from `apps/hue`, which is where it was first needed. `apps/terminal`
defaulted to a bare `"monospace"`, and unifying on this is the visible half of
`CLI3`.
*/
/**
The bundled family, alone.

Named separately from the preference list because the styled-face defaults have
to say a $(B family), not a list: an override is resolved as
`<spec>:bold` / `:italic` / `:bold:italic`, and a comma-separated list is not a
pattern fontconfig can style.
*/
enum defaultGuiFontFamily = "Maple Mono NF CN";

/// ditto
enum defaultGuiFont =
    defaultGuiFontFamily ~ "," ~
    "FiraCode Nerd Font Mono,JetBrainsMono Nerd Font Mono,JetBrains Mono," ~
    "CaskaydiaCove Nerd Font Mono,Cascadia Code,Hack Nerd Font Mono,Hack," ~
    "Iosevka Term,Iosevka,Source Code Pro,DejaVu Sans Mono,monospace";

/// The default `--font-size`, in points. One value for every application
/// (`CLI3`): `apps/terminal` used 13 and `apps/hue` 14, and there is no
/// per-application override — see `UIAPP-O1` for why the argument parser makes
/// one impossible to express as a field initializer.
///
/// Points, not pixels: the setup path resolves this against the display's real
/// density, so the same number is the same physical size on a HiDPI panel.
enum int defaultFontSizePoints = 18;

/**
The default colour theme, by name.

Part of the shared vocabulary rather than each application's own, for the same
reason the font is: two applications that disagree about the default theme
disagree for no reason anyone chose. Resolved against
$(REF builtinThemes, sparkles,ui,themes) by whoever needs a `Theme`; this module
only fixes the name, so an application with its own theme source is not forced
through the built-in registry.
*/
enum defaultTheme = "tokyo-night";

/// The default window size, in $(B cells) — not pixels. The window is sized
/// from the loaded font's cell metrics, which is why `CLI5`'s ordering matters.
enum int defaultWindowCols = 100;
/// ditto
enum int defaultWindowRows = 30;

/**
The window/font flags, as fields.

Mixed into an application's own parameter struct, or into $(LREF GuiOptions) for
one that keeps them separate. Every field carries its `@CliOption` here, so the
help text is written once and two applications cannot describe the same flag
differently.
*/
mixin template GuiCliFields()
{
    import sparkles.core_cli.args : CliOption;
    import sparkles.ui_app.gui_options : defaultFontSizePoints, defaultGuiFont,
        defaultGuiFontFamily, defaultTheme, defaultWindowCols, defaultWindowRows;

    @CliOption("font|f",
        "Font for the window: a path, a family name, or a fontconfig "
        ~ "preference list (comma-separated; the first installed family wins).")
    string font = defaultGuiFont;

    @CliOption("font-size|s",
        "Font size in points. Resolved against the display's real density, so "
        ~ "the same value is the same physical size on a HiDPI panel.")
    int fontSize = defaultFontSizePoints;

    @CliOption("font-bold",
        "Bold face: a family, a fontconfig pattern, or a font file. Empty "
        ~ "falls back to whatever styled sibling the primary family's own "
        ~ "directory offers.")
    string fontBold = defaultGuiFontFamily;

    @CliOption("font-italic",
        "Italic face. Where no italic resolves, italic text renders upright — "
        ~ "a synthetic slant is never faked, because it breaks the cell grid.")
    string fontItalic = defaultGuiFontFamily;

    @CliOption("font-bold-italic", "Bold-italic face.")
    string fontBoldItalic = defaultGuiFontFamily;

    @CliOption("font-codepoint-map",
        "Render a codepoint range from a specific family (repeatable): "
        ~ "'U+XXXX-U+YYYY,U+ZZZZ=Family'.")
    string[] fontCodepointMap;

    @CliOption("font-dir",
        "Resolve fonts by scanning this directory instead of fontconfig "
        ~ "(repeatable). Makes a build's font selection deterministic: no "
        ~ "fc-match subprocess, and no dependence on the host's fontconfig "
        ~ "configuration.")
    string[] fontDir;

    @CliOption("theme",
        "Colour theme, by name (see sparkles.ui.themes for the built-in set). "
        ~ "Applies to every target, not only the window.")
    string theme = defaultTheme;

    @CliOption("window-width", "Initial window width in cells.")
    int windowWidth = defaultWindowCols;

    @CliOption("window-height", "Initial window height in cells.")
    int windowHeight = defaultWindowRows;

    @CliOption("gui",
        "Force the window. With neither --gui nor --no-gui, a window opens "
        ~ "when one is available and the terminal is used otherwise.")
    bool gui;

    @CliOption("no-gui", "Force terminal output even when a display is available.")
    bool noGui;

    @CliOption("tui", "Alias for --no-gui.")
    bool tui;
}

/**
The window/font options as a standalone value.

Defined $(B by) the mixin, so there is exactly one declaration of these fields
in the repository and no second copy to drift.
*/
struct GuiOptions
{
    mixin GuiCliFields;
}

/**
The font faces an application asked for, without the CLI shape.

`resolveFontPath` and the loader take this rather than the whole options struct,
so a caller that computes its faces some other way — an Android build reading
them from a bundle — is not forced to synthesize command-line fields to say so.
*/
struct FontRequest
{
    string family = defaultGuiFont;      /// path, family, or preference list
    string bold = defaultGuiFontFamily;  /// empty = the family's own sibling
    string italic = defaultGuiFontFamily;     /// ditto
    string boldItalic = defaultGuiFontFamily; /// ditto
    string[] codepointMaps;         /// `--font-codepoint-map` entries
    string[] searchDirs;            /// scan these instead of asking fontconfig

    /// Whether to consult fontconfig. False as soon as a directory is given:
    /// `--font-dir` exists precisely to make selection deterministic, so
    /// falling back to fc-match would defeat it.
    bool useFontconfig() const @safe pure nothrow @nogc => searchDirs.length == 0;
}

/// The font request `o` describes.
///
/// `o` is taken `const` rather than `in`: under `-preview=in` that would make it
/// `scope`, and the returned request borrows `o`'s strings — which are immutable
/// and outlive the call, but a `scope` parameter cannot say so.
FontRequest fontRequestOf(O)(const O o) @safe pure nothrow
{
    FontRequest r;
    r.family = o.font;
    r.bold = o.fontBold;
    r.italic = o.fontItalic;
    r.boldItalic = o.fontBoldItalic;
    r.codepointMaps = o.fontCodepointMap.dup;
    r.searchDirs = o.fontDir.dup;
    return r;
}

/**
The theme `o` names, or `null`.

Returns a pointer into the built-in registry rather than a copy: the themes are
`immutable`, so there is nothing to protect and nothing to duplicate. `null` for
a name no built-in carries, so a caller reports a typo instead of silently
rendering in something the user did not choose.
*/
immutable(Theme)* resolveTheme(O)(const O o)
{
    import sparkles.ui.themes : builtinThemes;

    return o.theme in builtinThemes;
}

/// The window size `o` asks for, in cells.
struct WindowCells
{
    int cols; /// ditto
    int rows; /// ditto
}

/// ditto
WindowCells windowCellsOf(O)(in O o) @safe pure nothrow @nogc
    => WindowCells(o.windowWidth, o.windowHeight);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui_app.gui_options.oneDeclaration")
@safe pure nothrow
unittest
{
    // The struct IS the mixin, so a field can only be declared once. If these
    // ever diverge, this stops compiling rather than drifting quietly.
    struct Mixed
    {
        mixin GuiCliFields;
    }

    static assert(GuiOptions.tupleof.length == Mixed.tupleof.length);
    static foreach (i, _; GuiOptions.tupleof)
    {
        static assert(is(typeof(GuiOptions.tupleof[i]) == typeof(Mixed.tupleof[i])));
        static assert(__traits(identifier, GuiOptions.tupleof[i])
            == __traits(identifier, Mixed.tupleof[i]));
    }
}

@("ui_app.gui_options.defaultsAreShared")
@safe pure nothrow
unittest
{
    // One set of defaults for every application (`CLI3`). The point size in
    // particular: `apps/terminal` used 13 and `apps/hue` 14, and the parser
    // cannot express a per-application override (`UIAPP-O1`).
    const o = GuiOptions.init;
    assert(o.fontSize == 18);
    assert(o.font == defaultGuiFont);
    assert(o.theme == "tokyo-night");

    // The styled faces name the bundled family outright rather than being left
    // to sibling auto-detection, so bold and italic come from the same family
    // as the primary instead of from whatever the fallback chain reached.
    assert(o.fontBold == defaultGuiFontFamily);
    assert(o.fontItalic == defaultGuiFontFamily);
    assert(o.fontBoldItalic == defaultGuiFontFamily);

    // A styled default must be a FAMILY, not the preference list: an override
    // is resolved as `<spec>:bold`, and a comma-separated list is not a
    // pattern fontconfig can style.
    static foreach (c; defaultGuiFontFamily)
        static assert(c != ',', "a styled face must name one family");
    assert(o.windowWidth == 100 && o.windowHeight == 30);

    // The bundled family leads: `nix build .#sparkles-fonts` ships it and the
    // Android build already treated it as primary. The spelling is the exact
    // one fontconfig matches — `Maple Mono` and `Maple Mono NF` resolve to an
    // unrelated proportional face, so a shortened name here would silently pass
    // the bundled font by.
    import std.algorithm : endsWith, startsWith;
    assert(o.font.startsWith("Maple Mono NF CN,"));

    // ...and the list still ends in a generic family, so a machine carrying
    // none of the named ones renders something anyway.
    assert(o.font.endsWith("monospace"));

    // Nothing is forced on by default — the backend decision is autodetection's
    // (`BKD`), not a flag's.
    assert(!o.gui && !o.noGui && !o.tui);
}

@("ui_app.gui_options.fontRequest")
@safe pure nothrow
unittest
{
    // A mixed-in parameter struct projects to the same request as the standalone
    // one, which is what lets an application keep its flags flat.
    struct AppParams
    {
        mixin GuiCliFields;
        string somethingElse;
    }

    AppParams p;
    p.fontBold = "Iosevka Bold";
    p.fontDir = ["/opt/fonts"];

    const r = fontRequestOf(p);
    assert(r.family == defaultGuiFont);
    assert(r.bold == "Iosevka Bold", "an explicit face wins");
    assert(r.italic == defaultGuiFontFamily, "an untouched face keeps the default");

    // `--font-dir` turns fontconfig off. It exists to make selection
    // deterministic; consulting fc-match anyway would defeat the flag.
    assert(!r.useFontconfig);
    assert(GuiOptions.init.fontRequestOf.useFontconfig);
}

@("ui_app.gui_options.theme")
@safe
unittest
{
    // The default resolves against the built-in set — a default naming a theme
    // that does not exist would be a startup failure nobody sees until they run
    // the thing.
    auto t = resolveTheme(GuiOptions.init);
    assert(t !is null && t.name == "tokyo-night");

    // A name no built-in carries is reported, not silently substituted: a typo
    // should say so rather than render in something the user did not choose.
    GuiOptions bad;
    bad.theme = "tokoy-night";
    assert(resolveTheme(bad) is null);

    // The registry's alias spellings work too, since resolution is its.
    GuiOptions alt;
    alt.theme = "tokyonight";
    assert(resolveTheme(alt).name == "tokyo-night");
}

@("ui_app.gui_options.windowCells")
@safe pure nothrow @nogc
unittest
{
    // Cells, not pixels — the window is sized from the loaded font's metrics,
    // which is why the setup order in `CLI5` is part of the contract.
    GuiOptions o;
    o.windowWidth = 120;
    o.windowHeight = 40;
    assert(windowCellsOf(o) == WindowCells(120, 40));
}
