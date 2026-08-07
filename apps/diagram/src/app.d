/**
The entry point: parse the shared window/font/theme CLI, run the component.

Deliberately the whole file (`DIA6`): everything with behavior lives in
`diagram_app.d`, inside the test build.
*/
module app;

import sparkles.core_cli.args : HelpInfo, parseCliArgs;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;

import diagram_app : DiagramApp;

int main(string[] args)
{
    // Mutable: GuiOptions carries array fields (the codepoint maps), so a
    // `const` copy cannot convert back when RunConfig takes it by value.
    auto gui = args.parseCliArgs!GuiOptions(HelpInfo(
        "diagram",
        "A draw.io-style diagram board — infinite canvas, camera, minimap.",
        null,
    ));

    RunConfig cfg = {
        title: "diagram",
        gui: gui,
        motion: true, // hover affordances want bare pointer motion
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
