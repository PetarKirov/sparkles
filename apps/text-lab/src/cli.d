/**
The text lab's command line, shared by both entries — the desktop `main`
(app.d) and the Android activity (android_entry.d): the shared window and font
options, plus `--shot`, which captures a frame and exits (for a headless check).
*/
module cli;

import std.path : buildPath;

import sparkles.base.logger : LogLevel;
import sparkles.core_cli.args : CliError, CliExpected, Command, Flatten, Option, RunExpected;
import sparkles.ui_app.gui_options : GuiOptions, NativeOptions;
import sparkles.ui_app.host : PointerUnit, RunConfig, TouchGestures;
import sparkles.ui_app.run : asRunResult;
import sparkles.ui_app.run_app : runApp;
import sparkles.ui_vulkan.text_rendering : Compositing, Hinting;
import sparkles.ui_vulkan.coverage_geometry : CoverageMode;
import sparkles.base.term_color : RgbColor;

import lab : framePalette, Lab, SweepMode;
import unicode_samples : Showcase;

/// The lab from `args`, as `main` receives them; the process's exit status.
int run(string[] args)
{
    import sparkles.core_cli.args : runCli;

    return runCli!TextLab(args);
}

/// The lab's command line: the shared window, font and native-window options,
/// and the lab's own.
@(Command("text-lab",
    shortDescription: "The Vulkan canvas's text rendering, switched live and seen through a loupe.",
))
struct TextLab
{
    @(Option("log-level", description: "Log level: trace | info | warning | error | critical | off."))
    LogLevel logLevel = LogLevel.warning;

    /// A specimen wants more lines, at a smaller size, than the shared
    /// defaults leave room for.
    @Flatten("GUI Options")
    GuiOptions gui = GuiOptions(fontSize: 12, windowHeight: 40);

    @Flatten("Native Window Options")
    NativeOptions native;

    @(Option("shot", description: "Capture a frame into this PNG, then exit.", placeholder: "PATH"))
    string shot;
    @(Option("settings", description: "Open the generated settings sheet at startup."))
    bool settings;
    @(Option("showcase", description: "Sample group: overview, latin, rtl, indic, southeastAsian, cjk, world, historic, symbols, emoji, icons."))
    Showcase showcase;
    @(Option("sample-row", description: "Start at this sample row (one-based)."))
    uint sampleRow = 1;
    @(Option("wrapped-row-offset", description: "Skip wrapped rows below the selected sample row."))
    uint wrappedRowOffset;
    @(Option("picker", description: "Open the font picker at startup."))
    bool picker;
    @(Option("font-face-index", description: "Collection member of the startup font."))
    uint fontFaceIndex;
    @(Option("font-variation", description: "Declared axes as TAG=VALUE pairs, for example wght=700,opsz=24."))
    string fontVariation;
    @(Option("ui-follows-specimen", description: "Apply specimen typography to the UI too; F12 restores stable UI typography."))
    bool uiFollowsSpecimen;
    @(Option("sweep-frames", description: "Sweep em size and declared axes each frame, then exit (pair with --debug trace-frames)."))
    uint sweepFrames;
    @(Option("sweep-mode", description: "Sweep workload: all, render (fixed-font redraw), size, weight, axes."))
    SweepMode sweepMode;
    @(Option("raster-workers", description: "Coverage raster workers, 1–4 (1 runs on the frame thread)."))
    uint rasterWorkers = 2;
    @(Option("coverage-mode", description: "Experimental coverage comparison: cpu (default), edges, bands."))
    CoverageMode coverageMode;
    @(Option("coverage-report", description: "Write per-batch worker-time sums and caller wall time to CSV.", placeholder: "PATH"))
    string coverageReport;
    @(Option("compositing", description: "gamma, linear or linear-corrected."))
    Compositing compositing = Compositing.linearCorrected;
    @(Option("contrast", description: "Coverage contrast for linear-corrected, 0–1."))
    float contrast = 0.25f;
    @(Option("hinting", description: "none or light."))
    Hinting hinting = Hinting.light;
    @(Option("no-shaping", description: "Draw each cluster's first glyph, unshaped."))
    bool noShaping;
    @(Option("no-loupe", description: "Keep both specimen panels unobscured."))
    bool noLoupe;
    @(Option("loupe-at", description: "Point the loupe at this pixel (x,y) instead of the pointer.", placeholder: "X,Y"))
    string loupeAt;

    /// Opens the lab the options describe.
    RunExpected!void run()
    {
        import sparkles.core_cli.args : failRun;

        auto configured = configure(this);
        if (configured.hasError)
            return failRun(configured.error.message);
        Lab lab = configured.value;
        RunConfig cfg = {
            gui: gui,
            native: native,
            framePalette: framePalette,
            hasFramePalette: true,
            launchBackground: RgbColor(0x11, 0x11, 0x1b),
            hasLaunchBackground: true,
            motion: true, // the loupe follows the pointer
            pointerUnit: PointerUnit.pixels,
            fractionalScroll: true,
            touchGestures: TouchGestures.multiTouchOnly, // single touch for sliders/buttons; pinch for zoom
        };
        // The shared --font/--font-size options select the specimen. Its
        // controls start in the host's normal face at a stable size.
        cfg.gui.font = GuiOptions.init.font;
        cfg.gui.fontSize = 12;
        cfg.gui.fontBold = GuiOptions.init.fontBold;
        cfg.gui.fontItalic = GuiOptions.init.fontItalic;
        cfg.gui.fontBoldItalic = GuiOptions.init.fontBoldItalic;
        version (Android) {} else cfg.gui.fontDir = null;
        // The lab has no terminal form: its window is the point, so it opens
        // one without being asked.
        if (!cfg.gui.noGui && !cfg.gui.tui)
            cfg.gui.gui = true;
        // The desktop's and the driver's name for the lab; its APK is the
        // same package (`nix/packages/android/text-lab.nix`).
        cast(void) cfg.app.id.assign("dev.petar_kirov.sparkles.text_lab");
        cast(void) cfg.app.name.assign("Sparkles Text Lab");
        version (Android)
        {
            import sparkles.android.activity : internalDataPath;

            lab.screenshotDir = internalDataPath;
            lab.fontCache = buildPath(internalDataPath, "font-catalog");
        }
        const result = runApp(lab, cfg);
        if (lab.fontError.length)
            return failRun(lab.fontError);
        return asRunResult(result, "text-lab");
    }
}

/**
The lab the options describe, or the error that rejects them: what the
parser cannot judge alone — a contrast outside 0–1, a loupe point that is
not two pixel coordinates, a shot with no window to capture.
*/
CliExpected!Lab configure(in TextLab o)
{
    import std.conv : ConvException, to;
    import std.math : isNaN;
    import std.string : split;
    import sparkles.ui.geometry : Point;
    import sparkles.base.expected : err, ok;

    static CliExpected!Lab reject(string message)
        => err!Lab(CliError(kind: CliError.Kind.parse, message: message));

    if (o.contrast.isNaN || o.contrast < 0 || o.contrast > 1)
        return reject("--contrast must be between 0 and 1");
    if (o.rasterWorkers < 1 || o.rasterWorkers > 4)
        return reject("--raster-workers must be between 1 and 4");
    if (o.shot.length && (o.gui.tui || o.gui.noGui))
        return reject("--shot captures the window: it needs the GUI, not --tui or --no-gui");
    Lab lab;
    import std.path : buildPath;
    import std.process : environment;

    lab.discoverFonts = true;
    lab.model.font.size = o.gui.fontSize;
    lab.model.font.index = o.fontFaceIndex;
    lab.model.font.uiFollows = o.uiFollowsSpecimen;
    lab.model.samples.group = o.showcase;
    lab.model.samples.firstRow = o.sampleRow;
    lab.model.samples.wrappedOffset = o.wrappedRowOffset > 256 ? 256 : o.wrappedRowOffset;
    lab.sweepFrames = o.sweepFrames;
    lab.sweepMode = o.sweepMode;
    lab.rasterWorkers = o.rasterWorkers;
    lab.coverageMode = o.coverageMode;
    lab.coverageReport = o.coverageReport;
    lab.fontDirectories = o.gui.fontDir.dup;
    const state = environment.get("XDG_STATE_HOME", buildPath(environment.get("HOME", "."), ".local", "state"));
    lab.fontCache = buildPath(state, "sparkles", "text-lab", "fonts");
    lab.fontVariations = o.fontVariation;
    if (o.gui.font != GuiOptions.init.font)
        lab.fontSpecification = o.gui.font;
    lab.pickerAtStart = o.picker;
    lab.sheetOpen = o.settings;
    lab.shotPath = o.shot;
    lab.settings.compositing = o.compositing;
    lab.settings.contrast = o.contrast;
    lab.settings.hinting = o.hinting;
    lab.settings.shaping = !o.noShaping;
    lab.loupe.shown = !o.noLoupe;
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
    TextLab o;
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
    static string why(void delegate(ref TextLab) @safe set)
    {
        TextLab o;
        set(o);
        const r = configure(o);
        return r.hasError ? r.error.message : null;
    }

    assert(why((ref o) {}) is null, "the defaults are a lab");
    assert(why((ref o) { o.contrast = 1.5f; }) == "--contrast must be between 0 and 1");
    assert(why((ref o) { o.contrast = -0.1f; }) !is null);
    assert(why((ref o) { o.contrast = float.nan; }) !is null);
    assert(why((ref o) { o.rasterWorkers = 0; }) == "--raster-workers must be between 1 and 4");
    assert(why((ref o) { o.rasterWorkers = 5; }) !is null);
    foreach (bad; ["5", "1,2,3", "x,2", "1,", "-1,2", ",7"])
        assert(why((ref o) { o.loupeAt = bad; }) !is null, bad);
    assert(why((ref o) { o.shot = "a.png"; o.gui.tui = true; }) !is null);
    assert(why((ref o) { o.shot = "a.png"; o.gui.noGui = true; }) !is null);
}

@("text_lab.cli.anUnknownCompositingIsAParseError")
@system unittest
{
    import sparkles.core_cli.args : parseCli;

    auto parsed = parseCli!TextLab(["text-lab", "--compositing", "bogus"]);
    assert(!parsed && parsed.error.kind == CliError.Kind.parse);
    auto good = parseCli!TextLab(["text-lab", "--compositing", "linear-corrected", "--hinting", "none"]);
    assert(good, good.error.message);
    assert(good.value.compositing == Compositing.linearCorrected
        && good.value.hinting == Hinting.none);
}

@("text_lab.cli.theLabsDefaultsYieldToWhatIsTyped")
@system unittest
{
    import sparkles.core_cli.args : parseCli;
    import sparkles.ui_app.gui_options : defaultFontSizePoints, defaultWindowRows, WindowSystem;

    auto bare = parseCli!TextLab(["text-lab"]);
    assert(bare, bare.error.message);
    assert(bare.value.gui.fontSize == 12 && bare.value.gui.windowHeight == 40);
    // The shared default, typed, is what the user asked for: it stays.
    auto typed = parseCli!TextLab(["text-lab", "--font-size", "18", "--window-height", "30"]);
    assert(typed, typed.error.message);
    assert(typed.value.gui.fontSize == defaultFontSizePoints);
    assert(typed.value.gui.windowHeight == defaultWindowRows);
    auto native = parseCli!TextLab(["text-lab", "--window-system", "x11", "--debug", "log-events",
        "--debug=lose-device-at=3", "--appearance", "dark"]);
    assert(native, native.error.message);
    with (native.value.native)
        assert(windowSystem == WindowSystem.x11 && debugging.logEvents
            && debugging.loseDeviceAt == 3 && appearance == "dark");
}
