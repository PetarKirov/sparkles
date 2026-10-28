/**
The text lab's entry point: the shared window and font options, plus
`--shot`, which captures a frame and exits (for a headless check).
*/
module app;

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
}

int main(string[] args)
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
    RunConfig cfg = {
        title: "text lab",
        gui: gui,
        motion: true, // the loupe follows the pointer
        pointerUnit: PointerUnit.pixels,
    };
    Lab lab;
    lab.shotPath = parsed.value.shot;
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
