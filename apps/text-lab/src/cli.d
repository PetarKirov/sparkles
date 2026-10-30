/**
The text lab's command line, shared by both entries — the desktop `main`
(app.d) and the Android activity (android_entry.d): the shared window and font
options, plus `--shot`, which captures a frame and exits (for a headless check).
*/
module cli;

import std.traits : isDynamicArray, isSomeString;

import sparkles.core_cli.args : CliError, CliExpected, HelpInfo, Option, parseCli,
    reportCliError;
import sparkles.ui_app.gui_options : GuiCliFields, GuiOptions;
import sparkles.ui_app.host : PointerUnit, RunConfig;
import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;
import sparkles.ui_vulkan.text_rendering : Compositing, Hinting;

import lab : Lab;

/// The shared window/font/theme options, and the lab's own.
struct LabOptions
{
    mixin GuiCliFields;
    @(Option("shot", description: "Capture a frame into this PNG, then exit.", placeholder: "PATH"))
    string shot;
    @(Option("compositing", description: "gamma, linear or linearCorrected."))
    Compositing compositing = Compositing.linearCorrected;
    @(Option("contrast", description: "Coverage contrast for linearCorrected, 0–1."))
    float contrast = 0.25f;
    @(Option("hinting", description: "none or light."))
    Hinting hinting = Hinting.light;
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
    auto configured = configure(parsed.value);
    if (!configured)
        return reportCliError(configured.error);
    Lab lab = configured.value;
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
    version (Android)
    {
        import sparkles.android.activity : internalDataPath;

        lab.screenshotDir = internalDataPath;
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

/**
The lab the options describe, or the error that rejects them: what the
parser cannot judge alone — a contrast outside 0–1, a loupe point that is
not two pixel coordinates, a shot with no window to capture.
*/
CliExpected!Lab configure(in LabOptions o)
{
    import std.conv : ConvException, to;
    import std.math : isNaN;
    import std.string : split;
    import sparkles.ui.geometry : Point;
    import expected : err, ok;

    static CliExpected!Lab reject(string message)
        => err!Lab(CliError(kind: CliError.Kind.parse, message: message));

    if (o.contrast.isNaN || o.contrast < 0 || o.contrast > 1)
        return reject("--contrast must be between 0 and 1");
    if (o.shot.length && (o.tui || o.noGui))
        return reject("--shot captures the window: it needs the GUI, not --tui or --no-gui");
    Lab lab;
    lab.shotPath = o.shot;
    lab.settings.compositing = o.compositing;
    lab.settings.contrast = o.contrast;
    lab.settings.hinting = o.hinting;
    lab.settings.shaping = !o.noShaping;
    if (o.loupeAt.length)
    {
        enum shape = "--loupe-at takes a pixel as X,Y, both 0 or more";
        const xy = o.loupeAt.split(",");
        if (xy.length != 2)
            return reject(shape);
        try
        {
            const x = xy[0].to!int, y = xy[1].to!int;
            if (x < 0 || y < 0)
                return reject(shape);
            lab.pointAt(Point(x, y));
        }
        catch (ConvException)
            return reject(shape);
    }
    return ok!CliError(lab);
}

@("text_lab.cli.optionsBecomeTheLab")
@system unittest
{
    LabOptions o;
    o.compositing = Compositing.gamma;
    o.hinting = Hinting.none;
    o.contrast = 0.5f;
    o.noShaping = true;
    o.loupeAt = "12,34";
    o.shot = "out.png";
    const lab = configure(o);
    assert(lab.hasValue);
    assert(lab.value.settings.compositing == Compositing.gamma);
    assert(lab.value.settings.hinting == Hinting.none);
    assert(lab.value.settings.contrast == 0.5f && !lab.value.settings.shaping);
    assert(lab.value.shotPath == "out.png");
}

@("text_lab.cli.whatTheParserCannotJudgeIsRejected")
@system unittest
{
    static string why(void delegate(ref LabOptions) @safe set)
    {
        LabOptions o;
        set(o);
        const r = configure(o);
        return r.hasError ? r.error.message : null;
    }

    assert(why((ref o) {}) is null, "the defaults are a lab");
    assert(why((ref o) { o.contrast = 1.5f; }) == "--contrast must be between 0 and 1");
    assert(why((ref o) { o.contrast = -0.1f; }) !is null);
    assert(why((ref o) { o.contrast = float.nan; }) !is null);
    foreach (bad; ["5", "1,2,3", "x,2", "1,", "-1,2", ",7"])
        assert(why((ref o) { o.loupeAt = bad; }) !is null, bad);
    assert(why((ref o) { o.shot = "a.png"; o.tui = true; }) !is null);
    assert(why((ref o) { o.shot = "a.png"; o.noGui = true; }) !is null);
}

@("text_lab.cli.anUnknownCompositingIsAParseError")
@system unittest
{
    auto parsed = parseCli!LabOptions(["text-lab", "--compositing", "bogus"],
        HelpInfo("text-lab", "", null));
    assert(!parsed && parsed.error.kind == CliError.Kind.parse);
    auto good = parseCli!LabOptions(["text-lab", "--compositing", "linear", "--hinting", "none"],
        HelpInfo("text-lab", "", null));
    assert(good && good.value.compositing == Compositing.linear
        && good.value.hinting == Hinting.none);
}
