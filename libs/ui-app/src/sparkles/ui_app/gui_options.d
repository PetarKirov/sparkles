/**
The window and font command line, declared once (`CLI1`–`CLI3`).

Both existing applications grew the same flags independently — `--font`,
`--font-size`, `--window-width`, `--font-dir`, `--font-codepoint-map` — with
different help text, different resolution order, and different defaults for the
same setting. Nothing made them disagree on purpose; there was simply no one
place to put them.

$(B The fields live in one struct, and every application embeds it.) Two parallel
declarations of one vocabulary is the defect being removed, so this module holds
the only copy: $(LREF GuiOptions), which an application flattens into its own
command struct (`@Flatten`), so its flags stay flat and nothing copies them field
by field.
*/
module sparkles.ui_app.gui_options;

import sparkles.core_cli.args : Description, Flatten, Option, Switches;
import sparkles.metadata.case_style : CaseStyle;
import sparkles.ui_app.frame_schedule : FrameSchedulePolicy;
import sparkles.metadata.wire : WireCase;
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

/// The default `--font-size`, in points: one value shared by every application
/// (`CLI3`, `UIAPP-O1`; `apps/terminal` used 13 and `apps/hue` 14). An
/// application whose content needs another size gives it in its flattened
/// `GuiOptions` field's initializer, so a typed `--font-size` still wins.
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

/// Uiua's non-ASCII primitive glyphs, formatted subscripts, and canonicalized
/// identifier suffixes render from Uiua386 — the shared default
/// `--font-codepoint-map` entry on every application (it mirrors the machine
/// config's uiua386glyphs.nix; Android bundles the face, a desktop without it
/// simply never matches the family).
enum uiuaCodepointMap =
    "U+00A4,U+00AC,U+00AF-U+00B1,U+00D7,U+00F7,U+02D9,U+02DC,U+03B7," ~
    "U+03C0,U+03C4,U+1D62-U+1D63,U+2032-U+2034,U+203C,U+2045," ~
    "U+207F-U+2089,U+208B,U+2091,U+2099,U+2102,U+2198-U+2199,U+21A5," ~
    "U+21A7,U+21AF,U+21BB,U+21CC,U+21E1,U+2202,U+220A,U+2218,U+221A," ~
    "U+221E,U+2220,U+2227-U+222B,U+2235,U+223F,U+224D,U+2260-U+2261," ~
    "U+2264-U+2265,U+2282-U+2283,U+228F,U+2293,U+2295,U+2297," ~
    "U+2299-U+229C,U+229E-U+229F,U+22A1-U+22A3,U+22A5,U+22B8,U+22C5," ~
    "U+22D5,U+22EF,U+2305,U+2308,U+230A,U+2315,U+231D-U+231F,U+2335," ~
    "U+2346,U+2349,U+234F,U+2356,U+235A,U+235C,U+2361-U+2365,U+2369," ~
    "U+25A1,U+25B3,U+25BD,U+25C7,U+25CC,U+25E0-U+25E1,U+25EB,U+25F0," ~
    "U+25F4,U+25FF,U+2607,U+266D,U+2682,U+27DC,U+2919-U+291A,U+2938," ~
    "U+29B7,U+29C5-U+29C6,U+29C8,U+29CB,U+29FB,U+2A02,U+2A2A,U+2A2C," ~
    "U+2A5C,U+2B1A,U+2BFE,U+1D110=Uiua386";

/// The default window size, in $(B cells) — not pixels. The window is sized
/// from the loaded font's cell metrics, which is why `CLI5`'s ordering matters.
enum int defaultWindowCols = 100;
/// ditto
enum int defaultWindowRows = 30;

/**
The interface face's option (design-system `GLY10`), declared once (`CLI1`):
$(LREF GuiOptions) flattens it beside the other font options, and an
application whose font options are its own — `apps/terminal`, whose flags are
the highest layer of its configuration — flattens this group alone and passes
it on in `RunConfig.gui.interfaceFont`.
*/
struct InterfaceFontOptions
{
    @(Option("ui-font", placeholder: "FONT", description:
        "Proportional face for the interface — tabs, buttons, menus, labels "
        ~ "and documentation: a path, a family name, or a comma-separated "
        ~ "preference list. Default: the desktop's interface font, else the "
        ~ "first installed of Inter, Adwaita Sans, Cantarell, Noto Sans, Roboto, "
        ~ "DejaVu Sans… (Roboto on Android). 'none' keeps the interface in the "
        ~ "cell font."))
    string uiFont; ///
}

/**
The window/font/theme options, declared once (`CLI1`). Every field carries its
`@(Option(...))` here, so the help text is written once and two applications
cannot describe the same flag differently.

An application embeds it in its command struct as `@Flatten("GUI Options")
GuiOptions gui;` — the flags stay flat (`--font`, not `--gui.font`) — and
passes it on in `RunConfig.gui` (`CLI2`). An application that needs other
defaults gives them in that field's initializer, `GuiOptions gui =
GuiOptions(fontSize: 12);`, so a flag the user types still wins (`CLI3`).
*/
struct GuiOptions
{

    @(Option("font|f", description:
        "Font for the window: a path, a family name, or a fontconfig "
        ~ "preference list (comma-separated; the first installed family wins)."))
    string font = defaultGuiFont;

    @(Option("font-size|s", description:
        "Font size in points. Resolved against the display's real density, so "
        ~ "the same value is the same physical size on a HiDPI panel."))
    int fontSize = defaultFontSizePoints;

    @(Option("font-bold", description:
        "Bold face: a family, a fontconfig pattern, or a font file. Empty "
        ~ "falls back to whatever styled sibling the primary family's own "
        ~ "directory offers."))
    string fontBold = defaultGuiFontFamily;

    @(Option("font-italic", description:
        "Italic face. Where no italic resolves, italic text renders upright — "
        ~ "a synthetic slant is never faked, because it breaks the cell grid."))
    string fontItalic = defaultGuiFontFamily;

    @(Option("font-bold-italic", description: "Bold-italic face."))
    string fontBoldItalic = defaultGuiFontFamily;

    /// `--ui-font`, as its own group (`InterfaceFontOptions`).
    @Flatten
    InterfaceFontOptions interfaceFont;

    @(Option("font-codepoint-map", description:
        "Render a codepoint range from a specific family (repeatable): "
        ~ "'U+XXXX-U+YYYY,U+ZZZZ=Family'. Defaults to the Uiua386 glyph map; "
        ~ "a family that is not installed simply never matches."))
    string[] fontCodepointMap = [uiuaCodepointMap];

    @(Option("font-dir", description:
        "Resolve fonts by scanning this directory instead of fontconfig "
        ~ "(repeatable). Makes a build's font selection deterministic: no "
        ~ "fc-match subprocess, and no dependence on the host's fontconfig "
        ~ "configuration."))
    string[] fontDir;

    @(Option("theme", description:
        "Colour theme: a built-in name (see --list-themes where offered) or a "
        ~ "DTCG theme file (.tokens). Applies to every target, not only the window."))
    string theme = defaultTheme;

    @(Option("window-width", description: "Initial window width in cells."))
    int windowWidth = defaultWindowCols;

    @(Option("window-height", description: "Initial window height in cells."))
    int windowHeight = defaultWindowRows;

    // `noGui` MUST be declared before `gui`: the parser resolves a `--no-X`
    // token against the FIRST field it matches, in declaration order, and
    // `--no-gui` stripped is `gui` — declared the other way around, `--no-gui`
    // lands on `gui` as a negation (a no-op: it was already false) and the
    // force-terminal request is silently lost. hue learned this the hard way;
    // the regression test below keeps it learned.
    @(Option("no-gui", description:
        "Force terminal output even when a display is available."))
    bool noGui;

    @(Option("gui", description:
        "Force the window. With neither --gui nor --no-gui, a window opens "
        ~ "when one is available and the terminal is used otherwise."))
    bool gui;

    @(Option("tui", description: "Alias for --no-gui."))
    bool tui;
}

/**
Which window system the native (Vulkan) arm opens. `auto` takes Wayland where
`$WAYLAND_DISPLAY` names a compositor that answers, and X11 otherwise; Android
has only its own, whatever is asked.
*/
@WireCase(CaseStyle.kebabCase)
enum WindowSystem : ubyte
{
    auto_,   ///
    wayland, ///
    x11,     ///
    appkit,  /// macOS
}

/**
The native (Vulkan) arm's debug switches, taken by `--debug` as a
comma-separated list or one at a time (`--debug log-events --debug
lose-device-at=120`); `--debug=?` lists them.
*/
struct NativeDebug
{
    @Description("Log every window-system event the window receives, and their counts by kind when it closes.")
    bool logEvents; ///

    @Description("Log each frame's CPU and GPU time, and each frame its swapchain turned out stale for.")
    bool traceFrames; ///

    @Description("Run the device under the Vulkan validation layer, where it is installed.")
    bool vulkanValidation; ///

    @Description("Diagnose driver compatibility using Vulkan 1.1 shaders while retaining newer device features.")
    bool vulkanSpirv11; ///

    @Description("Diagnose driver compatibility using render passes instead of dynamic rendering.")
    bool vulkanRenderPass; ///

    @Description("Diagnose driver compatibility without optional pipeline-creation feedback.")
    bool vulkanNoFeedback; ///

    @Description("Log only the frames that took N ms or more, with trace-frames' detail.")
    uint traceFramesOver; ///

    @Description("Close the window after N frames are presented: a scripted run's end.")
    uint frames; ///

    @Description("Resize the window every 30 frames: toggle maximize on Wayland and AppKit, step through a band of sizes on X11.")
    bool resizeStress; ///

    @Description("Resize the window a few pixels every frame, sweeping a band of sizes the way a live drag does, where the client may size its window (X11, AppKit).")
    bool resizeDrag; ///

    @Description("Like resize-drag, but one way: sweep the band outward, then start over from its narrow end, so no width comes back within 120 frames — the cost of a drag that keeps going, which caches cannot answer from widths just left.")
    bool resizeSweep; ///

    @Description("Treat frame N as a lost device, which no software driver produces on demand, so the rebuild can be seen to redraw.")
    uint loseDeviceAt; ///

    @Description("Create the device and swapchain for present ids and waits 2, present timing and swapchain maintenance1 where the driver offers them, and take presentation times from them (the output-latency specification's OPL20-OPL24).")
    bool presentPath; ///

    @Description("With present-path, after frame N, switch to the next present mode the swapchain was created compatible with, without a rebuild, and report how many swapchains were built 30 frames on.")
    uint switchPresentModeAt; ///

    @Description("Measure each frame's device time with timestamp queries, and summarize it when the window closes.")
    bool gpuTiming; ///

    @Description("Write the run's last 4096 frames as a Chrome trace (Perfetto, chrome://tracing) to PATH when the window closes.")
    string frameTrace; ///

    @Description("Write the run's last 4096 frames to PATH when the window closes, tab-separated: number, start and display time in CLOCK_MONOTONIC nanoseconds, and the stream bytes delivered before the frame started — what joins a writer's log to the photons its bytes became.")
    string latencyLog; ///

    @Description("Read the frame thread's hardware counters (instructions, cycles, cache misses, page faults) for each frame, and summarize them when the window closes.")
    bool frameCounters; ///

    @Description("Capture frame N with RenderDoc, where its layer is in the process (renderdoccmd capture); measures GPU scopes, so the capture carries their debug labels.")
    uint renderdocCapture; ///

    @Description("Capture a presented frame into the PNG at PATH: the last of a frames=N run, else an early one — read back from the swapchain, so no screen-recording grant is needed.")
    string shot; ///
}

/**
The native (Vulkan) arm's options: the window system it opens, an appearance
pinned over the desktop's, and its debug switches, which report on standard
error (logcat on Android). An application flattens them beside $(LREF
GuiOptions) — `@Flatten("Native Window Options") NativeOptions native;` — and
passes them on in `RunConfig.native`; the other arms ignore them.
*/
struct NativeOptions
{
    @(Option("window-system", description:
        "The native window's window system: auto (Wayland where a compositor answers, else X11; AppKit on macOS), wayland, x11 or appkit."))
    WindowSystem windowSystem; ///

    @(Option("appearance", placeholder: "PREFS", description:
        "Pin the appearance over what the desktop says, comma-separated: dark or light, high-contrast, reduced-motion — what a golden capture or a test wants."))
    string appearance; ///

    @(Option("debug", placeholder: "SWITCH[,SWITCH…]", description:
        "The native window's debug switches, comma-separated or repeated; --debug=? lists them."))
    Switches!NativeDebug debugging; ///

    @(Option("frame-schedule", description:
        "When the native window starts a frame on Wayland: late (as late as still makes the next refresh it can reach, so it shows the newest output) or asap (as soon as the compositor allows)."))
    FrameSchedulePolicy frameSchedule; ///
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
    string[] searchDirs;            /// scan these instead of asking the system
    /// `--ui-font`: the interface face; empty for the desktop's, `none` for
    /// the cell font (`sparkles.ui_app.interface_font.uiFontFamilyOf`).
    string ui;

    /// Whether to consult the OS font database (fontconfig on Linux, CoreText
    /// on macOS). False as soon as a directory is given: `--font-dir` exists
    /// precisely to make selection deterministic, so asking the system anyway
    /// would defeat it.
    bool useSystemFontDb() const @safe pure nothrow @nogc => searchDirs.length == 0;
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
    static if (__traits(hasMember, O, "interfaceFont"))
        r.ui = o.interfaceFont.uiFont;
    return r;
}

/**
The theme `o` names: a built-in by name, else a theme file at that path
($(REF themeNamed, sparkles,ui,theme_file)), or the error that says why neither.

A built-in comes back as a pointer into the registry rather than a copy: the
themes are `immutable`, so there is nothing to protect. A name that is neither is
an error rather than a substitution, so a caller reports a typo instead of
rendering in something the user did not choose.
*/
auto resolveTheme(O)(const O o)
{
    import sparkles.ui.theme_file : themeNamed;

    return themeNamed(o.theme);
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

@("ui_app.gui_options.flattenedFlagsStayFlat")
@system
unittest
{
    import sparkles.core_cli.args : Flatten, Option, parseCli;

    // An application embeds the options, flattened: the flags keep their own
    // names beside the application's, and a default it gives in the field's
    // initializer holds until the user types the flag (`CLI2`, `CLI3`).
    struct App
    {
        @Flatten("GUI Options") GuiOptions gui = GuiOptions(fontSize: 12);
        @(Option("other", description: "")) bool other;
    }

    auto bare = parseCli!App(["app", "--font", "Iosevka", "--other"]);
    assert(bare, bare.error.message);
    assert(bare.value.gui.font == "Iosevka" && bare.value.other);
    assert(bare.value.gui.fontSize == 12, "the application's default");
    auto typed = parseCli!App(["app", "--font-size", "18"]);
    assert(typed && typed.value.gui.fontSize == 18, "what is typed wins");
}

@("ui_app.gui_options.defaultsAreShared")
@safe pure nothrow
unittest
{
    // One set of shared defaults (`CLI3`). The point size in particular:
    // `apps/terminal` used 13 and `apps/hue` 14 (`UIAPP-O1`).
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

@("ui_app.gui_options.noGuiIsAFlagNotANegation")
@system
unittest
{
    import sparkles.core_cli.args : parseCli;

    // The parser resolves `--no-X` against the FIRST field it matches, in
    // declaration order. With `gui` declared first, `--no-gui` would land on
    // it as a negation — a silent no-op (it was already false) — and the
    // force-terminal request would be lost. The declaration order in
    // `GuiOptions` is load-bearing; this is its regression test.
    auto parsed = parseCli!GuiOptions(["app", "--no-gui"]);
    assert(parsed);
    assert(parsed.value.noGui, "--no-gui must set the flag, not negate --gui");
    assert(!parsed.value.gui);

    // And the window force still works, as does the alias.
    auto g = parseCli!GuiOptions(["app", "--gui"]);
    assert(g && g.value.gui && !g.value.noGui);
    auto t = parseCli!GuiOptions(["app", "--tui"]);
    assert(t && t.value.tui);
}

@("ui_app.gui_options.fontRequest")
@safe
unittest
{
    GuiOptions p;
    p.fontBold = "Iosevka Bold";
    p.fontDir = ["/opt/fonts"];

    const r = fontRequestOf(p);
    assert(r.family == defaultGuiFont);
    assert(r.bold == "Iosevka Bold", "an explicit face wins");
    assert(r.italic == defaultGuiFontFamily, "an untouched face keeps the default");

    // `--font-dir` turns the system font database off. It exists to make
    // selection deterministic; asking fc-match/CoreText anyway would defeat
    // the flag.
    assert(!r.useSystemFontDb);
    assert(GuiOptions.init.fontRequestOf.useSystemFontDb);

    // The interface face: the desktop's unless `--ui-font` names one.
    assert(r.ui is null);
    p.interfaceFont.uiFont = "Inter";
    assert(fontRequestOf(p).ui == "Inter");
}

@("ui_app.gui_options.uiFontIsAnOption")
@system
unittest
{
    import sparkles.core_cli.args : parseCli;

    auto parsed = parseCli!GuiOptions(["app", "--ui-font", "Cantarell"]);
    assert(parsed && parsed.value.interfaceFont.uiFont == "Cantarell");
    assert(parseCli!GuiOptions(["app"]).value.interfaceFont.uiFont is null, "the desktop's by default");

    // The group alone, beside font options of an application's own.
    static struct OwnFonts
    {
        @(Option("font")) string font;
        @Flatten InterfaceFontOptions interfaceFont;
    }

    auto own = parseCli!OwnFonts(["app", "--font", "Iosevka", "--ui-font", "Inter"]);
    assert(own && own.value.font == "Iosevka" && own.value.interfaceFont.uiFont == "Inter");
    GuiOptions gui;
    gui.interfaceFont = own.value.interfaceFont;
    assert(fontRequestOf(gui).ui == "Inter", "passed on in `RunConfig.gui`");
}

@("ui_app.gui_options.theme")
@safe
unittest
{
    // The default resolves against the built-in set — a default naming a theme
    // that does not exist would be a startup failure nobody sees until they run
    // the thing.
    auto t = resolveTheme(GuiOptions.init);
    assert(t.hasValue && t.value.name == "tokyo-night");

    // A name no built-in carries is reported, not silently substituted: a typo
    // should say so rather than render in something the user did not choose.
    GuiOptions bad;
    bad.theme = "tokoy-night";
    assert(resolveTheme(bad).hasError);

    // The registry's alias spellings work too, since resolution is its.
    GuiOptions alt;
    alt.theme = "tokyonight";
    assert(resolveTheme(alt).value.name == "tokyo-night");
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
