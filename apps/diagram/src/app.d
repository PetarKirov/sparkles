/**
The entry point: parse the shared window/font/theme CLI, run the component.

Deliberately the whole file (`DIA6`): everything with behavior lives in
`diagram_app.d`, inside the test build.
*/
module app;

import std.traits : isDynamicArray, isSomeString;

import sparkles.core_cli.args : HelpInfo, parseCli, reportCliError;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.ui_app.host : PointerUnit, RunConfig;
import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;

import diagram_app : DiagramApp;

int main(string[] args)
{
    auto parsed = parseCli!GuiOptions(args, HelpInfo(
        "diagram",
        "A draw.io-style diagram board — infinite canvas, camera, minimap.",
        null,
    ));
    if (!parsed)
        return reportCliError(parsed.error);
    // Mutable: `GuiOptions` carries array fields (the codepoint maps), and the
    // parsed value arrives `const`, so the copy has to duplicate them.
    GuiOptions gui;
    static foreach (i, T; typeof(GuiOptions.tupleof))
    {{
        static if (isDynamicArray!T && !isSomeString!T)
            gui.tupleof[i] = parsed.value.tupleof[i].dup;
        else
            gui.tupleof[i] = parsed.value.tupleof[i];
    }}

    RunConfig cfg = {
        title: "diagram",
        gui: gui,
        motion: true, // hover affordances want bare pointer motion
        // Space+LMB pan needs key releases on the window (`IXN3` / `INP16`);
        // the terminal arm ignores this — it cannot report them.
        keyRelease: true,
        // The GUI board hit-tests in pixels at the drawn cell size (`HST18`);
        // the terminal arm ignores the unit and keeps delivering cells.
        pointerUnit: PointerUnit.pixels,
    };

    DiagramApp app;
    final switch (runApp(app, cfg))
    {
        case RunOutcome.ok:
            return 0;
        case RunOutcome.notInteractive:
            // A pipe or a requested static sink: nothing to render yet — the
            // board has no non-interactive projection in the MVP.
            import std.stdio : stderr;

            stderr.writeln("diagram needs an interactive target (a terminal or a display)");
            return 1;
        case RunOutcome.noBackend:
        case RunOutcome.openFailed:
            import std.stdio : stderr;

            stderr.writeln("no usable backend — try --tui in a terminal");
            return 1;
    }
}
