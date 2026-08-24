#!/usr/bin/env dub
/+ dub.sdl:
    name "gui_ab"
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "raylib-d" version="~>6.0.1"
    // raylib-d's `library` config does not declare it; the image API is
    // CPU-side, so no window is opened.
    libs "raylib"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// The A/B oracle a behaviour-preserving hue GUI change otherwise lacks — the
// window sibling of `tui-ab.d`.
//
// A terminal application's output IS its frame, which is what lets `tui-ab`
// compare bytes off a pty. A window has no such stream, so the frame has to be
// asked for: `HUE_GUI_SCREENSHOT` renders a fixed number of warm-up frames and
// writes a PNG (`DBG1`). That capture is specified to be REPRODUCIBLE — it
// waits out the async git-status worker, whose landing rebuilds the tree — so
// two runs of one binary produce identical bytes, and two builds that paint the
// same window produce identical bytes too.
//
//   dub run --single apps/hue/tools/gui-ab.d -- \
//       --old /tmp/hue-before --new apps/hue/build/hue \
//       --file docs/specs/ui/containers.md
//
// Three guards, each because its failure reads as a pass:
//
//   * A capture must be REPRODUCIBLE before it may be compared. Every side is
//     captured `--runs` times and a side that disagrees with itself is a
//     failure, not a diff — otherwise the tool blames the change for a race.
//   * The two binaries must actually DIFFER, because `dub build -c no-gui`
//     writes to the same path as the default config and A/B-ing one build
//     against itself reads as "identical" for the wrong reason.
//   * The display number is PINNED. `xvfb-run -a` picks a free number, but it
//     can land on the workstation's real display, where ambient keystrokes
//     reach the window and act as commands — a `t` toggles the copy format, an
//     arrow cycles the theme. That is recorded in the ui-app plan as something
//     that already happened.
//
// The font size is pinned too (`--font-size`, via `HUE_GUI_FONTSIZE`): a
// capture whose size quietly follows the panel's DPI is a broken oracle rather
// than a cosmetic difference (`CLI6`).
//
// `--pointer x,y` parks the pointer through `HUE_GUI_POINTER`, which is how a
// hovered scrollbar — a lit track, an expanded rail — becomes photographable.
//
// Exit status: 0 identical, 1 drift, 2 a setup problem — a missing binary,
// no `xvfb-run`, or a non-reproducible capture.
module gui_ab;

import std.algorithm : min;
import std.conv : to;
import std.digest.md : md5Of, toHexString;
import std.file : exists, isFile, mkdirRecurse, read, remove;
import std.format : format;
import std.path : absolutePath, buildPath;
import std.string : indexOf;
import std.process : Config, environment, spawnProcess, wait;
import std.stdio : stderr, writefln, writeln;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;

/// CLI surface (parsed by `sparkles:core-cli`, per the D-tooling guideline).
struct Params
{
    @(Option("old|o", description: "The baseline hue binary"))
    string old;

    @(Option("new|n", description: "The changed hue binary"))
    string new_ = "apps/hue/build/hue";

    @(Option("file|f", description: "The file to open in the viewer"))
    string file;

    @(Option("args", description: "Argument template; {file} is substituted"))
    string extraArgs = "view {file} --gui";

    @(Option("display|d", description: "X display number to pin Xvfb to"))
    int display = 99;

    @(Option("screen", description: "Xvfb screen geometry"))
    string screen = "1600x1000x24";

    @(Option("font-size", description: "Pixel font size; pins the capture"))
    int fontSize = 18;

    @(Option("frame", description: "Which frame to capture"))
    int frame = 20;

    @(Option("pointer|p", description: "Park the pointer at 'x,y' (device px)"))
    string pointer;

    @(Option("top|t", description: "Initial scroll line; brings a fence border "
        ~ "or a bar into frame"))
    int top = -1;

    @(Option("runs|r", description: "Captures per side; they must all agree"))
    int runs = 2;

    @(Option("out|O", description: "Directory for the captured PNGs"))
    string outDir = "/tmp/hue-gui-ab";

    @(Option("env|e", description: "Extra NAME=VALUE hooks, set on BOTH sides"))
    string[] extraEnv;
}

int main(string[] rawArgs)
{
    auto parsed = parseCli!Params(rawArgs, HelpInfo("gui-ab",
        "A/B two hue builds by their rendered window: `HUE_GUI_SCREENSHOT` "
        ~ "under a pinned Xvfb, captured twice a side so a race cannot be "
        ~ "mistaken for a difference.", null));
    if (!parsed)
        return reportCliError(parsed.error);
    auto p = parsed.value;

    if (!onPath("xvfb-run"))
    {
        stderr.writeln("gui-ab: `xvfb-run` is not on PATH — enter `nix develop`.");
        return 2;
    }
    if (p.old.length == 0)
    {
        stderr.writeln("gui-ab: --old is required (build the baseline first "
            ~ "and copy the binary aside).");
        return 2;
    }
    if (p.file.length == 0 || !p.file.exists)
    {
        stderr.writeln("gui-ab: --file must name a file to open.");
        return 2;
    }
    foreach (bin; [p.old, p.new_])
        if (!bin.exists || !bin.isFile)
        {
            stderr.writefln("gui-ab: no such binary: %s", bin);
            return 2;
        }

    // Guard two: one build compared against itself proves nothing, and is the
    // easy mistake because both configs write to the same target path.
    const oldBytes = cast(const(ubyte)[]) read(p.old);
    const newBytes = cast(const(ubyte)[]) read(p.new_);
    if (oldBytes == newBytes)
    {
        stderr.writeln("gui-ab: the two binaries are byte-identical, so this "
            ~ "comparison could not have detected anything. Rebuild one.");
        return 2;
    }
    writefln("binaries differ: old %s (%s bytes), new %s (%s bytes)",
        digest(oldBytes), oldBytes.length, digest(newBytes), newBytes.length);

    mkdirRecurse(p.outDir);

    ubyte[] oldPng, newPng;
    if (!capture(p, p.old, "old", oldPng))
        return 2;
    if (!capture(p, p.new_, "new", newPng))
        return 2;

    if (oldPng == newPng)
    {
        writefln("identical: %s bytes, %s", oldPng.length, digest(oldPng));
        return 0;
    }

    writeln("DRIFT: the two builds painted different windows.");
    writefln("  old %s (%s bytes) -> %s", digest(oldPng), oldPng.length,
        buildPath(p.outDir, "old.png"));
    writefln("  new %s (%s bytes) -> %s", digest(newPng), newPng.length,
        buildPath(p.outDir, "new.png"));
    reportPixelDiff(buildPath(p.outDir, "old.png"),
        buildPath(p.outDir, "new.png"), p.outDir);
    return 1;
}

/**
Where the two captures actually differ, in pixels.

A byte offset into a compressed PNG says nothing about the window — one
changed pixel shifts every subsequent byte — so the drift is reported as a
bounding box and a count, and the differing pixels are written out as a mask.
That is the difference between "something moved" and "the fence's bottom border
row changed and nothing else did".
*/
private void reportPixelDiff(string oldPath, string newPath, string outDir)
    @system
{
    import raylib : Color, ExportImage, GenImageColor, Image, ImageDrawPixel,
        LoadImage, LoadImageColors, UnloadImage, UnloadImageColors;
    import std.string : toStringz;

    auto a = LoadImage(oldPath.toStringz);
    auto b = LoadImage(newPath.toStringz);
    scope (exit)
    {
        UnloadImage(a);
        UnloadImage(b);
    }
    if (a.width != b.width || a.height != b.height)
    {
        writefln("  sizes differ: %sx%s vs %sx%s", a.width, a.height,
            b.width, b.height);
        return;
    }

    auto pa = LoadImageColors(a);
    auto pb = LoadImageColors(b);
    scope (exit)
    {
        UnloadImageColors(pa);
        UnloadImageColors(pb);
    }

    auto mask = GenImageColor(a.width, a.height, Color(0, 0, 0, 255));
    scope (exit)
        UnloadImage(mask);

    int minX = int.max, minY = int.max, maxX = -1, maxY = -1;
    size_t differing;
    foreach (y; 0 .. a.height)
        foreach (x; 0 .. a.width)
        {
            const i = y * a.width + x;
            if (pa[i].r == pb[i].r && pa[i].g == pb[i].g
                && pa[i].b == pb[i].b && pa[i].a == pb[i].a)
                continue;
            ++differing;
            if (x < minX) minX = x;
            if (y < minY) minY = y;
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
            ImageDrawPixel(&mask, x, y, Color(255, 0, 0, 255));
        }

    if (differing == 0)
    {
        writeln("  …but every pixel matches: the PNGs differ only in encoding.");
        return;
    }
    writefln("  %s of %s pixels differ (%.4f%%)", differing,
        cast(size_t)(a.width * a.height),
        100.0 * differing / (a.width * a.height));
    writefln("  bounding box: x %s..%s, y %s..%s (%sx%s)", minX, maxX,
        minY, maxY, maxX - minX + 1, maxY - minY + 1);

    // A handful of actual before/after colours, because "76 pixels moved" and
    // "76 pixels changed shade" are different bugs and the box cannot tell
    // them apart.
    size_t shown;
    foreach (y; 0 .. a.height)
    {
        foreach (x; 0 .. a.width)
        {
            const i = y * a.width + x;
            if (pa[i].r == pb[i].r && pa[i].g == pb[i].g
                && pa[i].b == pb[i].b && pa[i].a == pb[i].a)
                continue;
            writefln("    (%s,%s) %02x%02x%02x%02x -> %02x%02x%02x%02x",
                x, y, pa[i].r, pa[i].g, pa[i].b, pa[i].a,
                pb[i].r, pb[i].g, pb[i].b, pb[i].a);
            if (++shown == 4)
                break;
        }
        if (shown == 4)
            break;
    }
    const maskPath = buildPath(outDir, "diff-mask.png");
    ExportImage(mask, maskPath.toStringz);
    writefln("  mask -> %s", maskPath);
}

/// Captures `bin` `p.runs` times, failing unless every run agrees with itself.
private bool capture(in Params p, string bin, string side, out ubyte[] bytes)
{
    ubyte[] first;
    foreach (run; 0 .. p.runs)
    {
        ubyte[] shot;
        if (!shoot(p, bin, side, shot))
            return false;
        if (run == 0)
        {
            first = shot;
            continue;
        }
        if (shot != first)
        {
            stderr.writefln("gui-ab: %s is NOT reproducible — run %s differs "
                ~ "from run 0 (%s vs %s). A capture that disagrees with itself "
                ~ "cannot be compared against anything.",
                side, run, digest(shot), digest(first));
            return false;
        }
    }
    bytes = first;
    writefln("%s: %s bytes, %s (%s runs agreed)", side, bytes.length,
        digest(bytes), p.runs);
    return true;
}

/// One `xvfb-run` capture into `<outDir>/<side>.png`.
private bool shoot(in Params p, string bin, string side, out ubyte[] bytes)
{
    const png = side ~ ".png"; // relative — raylib's TakeScreenshot prepends CWD
    const full = buildPath(p.outDir, png);
    if (full.exists)
        remove(full);

    auto env = environment.toAA;
    env["HUE_GUI_SCREENSHOT"] = png;
    env["HUE_GUI_SCREENSHOT_FRAME"] = p.frame.to!string;
    env["HUE_GUI_FONTSIZE"] = p.fontSize.to!string;
    if (p.pointer.length)
        env["HUE_GUI_POINTER"] = p.pointer;
    if (p.top >= 0)
        env["HUE_GUI_TOP"] = p.top.to!string;
    // Everything else the harness understands, without this tool having to
    // learn each hook: the interesting states are reached by opening a pane or
    // replaying a script, and hardcoding a flag per hook meant the states that
    // most needed a picture were the ones that could not have one. Set on both
    // sides by construction — an A/B where the two runs saw different hooks
    // measures the hooks.
    foreach (kv; p.extraEnv)
    {
        const eq = kv.indexOf('=');
        if (eq <= 0)
        {
            stderr.writefln("gui-ab: --env expects NAME=VALUE, got '%s'", kv);
            return false;
        }
        env[kv[0 .. eq]] = kv[eq + 1 .. $];
    }
    // A Wayland socket in the environment makes raylib's GLFW prefer it over
    // the Xvfb display we just pinned, and the capture then lands on the real
    // compositor (or fails outright).
    env.remove("WAYLAND_DISPLAY");

    // The subcommand, the file and the flags are one template because their
    // ORDER matters: hue takes `view <file> --gui`, and a tool that appended
    // the file after the flags silently got the help text instead of a window.
    string[] cmd = ["xvfb-run", "-n", p.display.to!string,
        "-s", "-screen 0 " ~ p.screen, bin.absolutePath];
    foreach (a; p.extraArgs.splitArgs)
        cmd ~= a == "{file}" ? p.file.absolutePath : a;

    auto pid = spawnProcess(cmd, env: env, config: Config.none,
        workDir: p.outDir);
    const rc = pid.wait;
    if (!full.exists)
    {
        stderr.writefln("gui-ab: %s produced no screenshot (exit %s). Is this "
            ~ "a GUI-enabled build? `dub build :hue` (not --config=no-gui).",
            side, rc);
        return false;
    }
    bytes = cast(ubyte[]) read(full);
    return true;
}

/// Splits `--args` on spaces, dropping empties.
private string[] splitArgs(string s)
{
    import std.algorithm : filter, splitter;
    import std.array : array;

    return s.splitter(' ').filter!(a => a.length != 0).array;
}

private bool onPath(string tool)
{
    import std.algorithm : any;
    import std.array : split;

    auto path = environment.get("PATH", "");
    return path.split(':').any!(dir => buildPath(dir, tool).exists);
}

private string digest(in ubyte[] bytes)
    => md5Of(bytes).toHexString()[0 .. 12].idup;
