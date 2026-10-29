/**
The text lab's command line, shared by both entries — the desktop `main`
(app.d) and the Android activity (android_entry.d): the shared window and font
options, plus `--shot`, which captures a frame and exits (for a headless check).
*/
module cli;

import std.traits : isDynamicArray, isSomeString;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;
import sparkles.ui_app.gui_options : GuiCliFields, GuiOptions;
import sparkles.ui_app.host : PointerUnit, RunConfig;
import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;

import lab : Lab;

/// The shared window/font/theme options, and the lab's own.
struct LabOptions
{
    mixin GuiCliFields;
    @(Option("shot", description: "Capture a frame into this PNG, then exit.", placeholder: "PATH"))
    string shot;
    @(Option("compositing", description: "gamma, linear or linearCorrected."))
    string compositing = "linearCorrected";
    @(Option("contrast", description: "Coverage contrast for linearCorrected, 0–1."))
    float contrast = 0.25f;
    @(Option("hinting", description: "none or light."))
    string hinting = "light";
    @(Option("no-shaping", description: "Draw each cluster's first glyph, unshaped."))
    bool noShaping;
    @(Option("loupe-at", description: "Point the loupe at this pixel (x,y) instead of the pointer.", placeholder: "X,Y"))
    string loupeAt;
}

/// The lab from `args`, as `main` receives them; the process's exit status.
int run(string[] args)
{
    auto parsed = parseCli!LabOptions(args, HelpInfo("text-lab",
        "The Vulkan canvas's text rendering, switched live and seen through a loupe.", null));
    if (!parsed)
        return reportCliError(parsed.error);
    GuiOptions gui;
    static foreach (i, T; typeof(GuiOptions.tupleof))
    {{
        static if (isDynamicArray!T && !isSomeString!T)
            gui.tupleof[i] = parsed.value.tupleof[i].dup;
        else
            gui.tupleof[i] = parsed.value.tupleof[i];
    }}
    // A specimen wants more lines than the shared default size leaves room for.
    import sparkles.ui_app.gui_options : defaultFontSizePoints, defaultWindowRows;

    if (gui.fontSize == defaultFontSizePoints)
        gui.fontSize = 12;
    if (gui.windowHeight == defaultWindowRows)
        gui.windowHeight = 40;
    // The lab has no terminal form: its window is the point, so it opens one
    // without being asked.
    if (!gui.noGui && !gui.tui)
        gui.gui = true;
    RunConfig cfg = {
        title: "text lab",
        gui: gui,
        motion: true, // the loupe follows the pointer
        pointerUnit: PointerUnit.pixels,
    };
    import std.conv : to;
    import std.string : split;
    import sparkles.ui.geometry : Point;
    import sparkles.ui_vulkan.text_rendering : Compositing, Hinting;

    Lab lab;
    lab.shotPath = parsed.value.shot;
    version (Android)
    {
        import sparkles.android.activity : internalDataPath;

        lab.screenshotDir = internalDataPath;
    }
    lab.settings.compositing = parsed.value.compositing.to!Compositing;
    lab.settings.contrast = parsed.value.contrast;
    lab.settings.hinting = parsed.value.hinting.to!Hinting;
    lab.settings.shaping = !parsed.value.noShaping;
    if (parsed.value.loupeAt.length)
    {
        const xy = parsed.value.loupeAt.split(",");
        lab.pointAt(Point(xy[0].to!int, xy[1].to!int));
    }
    final switch (runApp(lab, cfg))
    {
        case RunOutcome.ok:
            return 0;
        case RunOutcome.notInteractive:
        case RunOutcome.noBackend:
        case RunOutcome.openFailed:
            import std.stdio : stderr;

            stderr.writeln("text-lab needs a window: run it with --gui on a display");
            return 1;
    }
}
