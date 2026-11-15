/**
The touch layout through the Vulkan canvas on a real driver, as a tablet
draws it: a recorded frame of each screen painted offscreen, so its pixels
can be read back (`FXU17`, `FXU19`).

Opt-in (`SPARKLES_VULKAN_READBACK=1`): it needs lavapipe and the validation
layer. With `$FILESET_EXPLORER_SHOTS` naming a directory, each frame is also
written there as a PNG, for a reader to look at.
*/
module vulkan_shot_test;

version (unittest):

import std.file : read, write;
import std.path : buildPath;
import std.process : environment;

import sparkles.base.term_color : RgbColor;
import sparkles.font : Ppem;
import sparkles.image.png : encodePng;
import sparkles.input : Event, Key, keyEvent;
import sparkles.test_runner.skip : skipTest;
import sparkles.ui.geometry : Size;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;
import sparkles.ui_vulkan.painter : FrameMetrics, TextMetrics;
import sparkles.ui_vulkan.testing : Canvas, readbackEnabled, readbackSkipReason, Rig;

import evaluate : Root;
import explorer : ExplorerApp;

// A tablet's cell at 12 points: 26 × 44 pixels, 16 dp tall at 2.75 pixels a dp.
private enum cellW = 26, cellH = 44;
private enum float density = 2.75f;
private enum cols = 120, rows = 44;

/// The explorer's frame after `script`, painted and read back: RGBA bytes.
ubyte[] shoot(Rig* rig, ref ExplorerApp app, in Event[] script)
{
    auto rec = runAppRecorded(app, RunConfig.init, script, (ref RecordingHost h) {
        h.size = Size(cols, rows);
        h.frameSeconds = 0;
    });
    rig.canvas.images(rec.imageRegistry);
    return rig.draw((ref Canvas c) { paint(c, rec.lastOps); },
        FrameMetrics(cellW: cellW, cellH: cellH, density: density), RgbColor(0, 0, 0));
}

/// Opens a rig the size of the frame, its cell font DejaVu Sans Mono.
Rig* openRig(string name)
{
    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    auto rig = new Rig;
    rig.open(name, cols * cellW, rows * cellH);
    const(ubyte)[][4] faces;
    faces[0] = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono.ttf"));
    faces[1] = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono-Bold.ttf"));
    faces[2] = faces[0];
    faces[3] = faces[1];
    assert(rig.canvas.cellFont(faces, Ppem.fromInteger(36).value,
        TextMetrics(ascent: 33, underlineY: 37, underlineHeight: 2, strikeY: 22)));
    return rig;
}

/// Writes `rgba` as `name`.png under `$FILESET_EXPLORER_SHOTS`, when it is set.
void keep(in ubyte[] rgba, string name)
{
    const dir = environment.get("FILESET_EXPLORER_SHOTS");
    if (dir.length)
        write(dir.buildPath(name ~ ".png"), encodePng(rgba, cols * cellW, rows * cellH));
}

/// The touch layout's screens, painted: the tree beside the help, and beside
/// the Export tab.
@("fileset_explorer.vulkan.touchScreens")
@system unittest
{
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = openRig("fileset-explorer-touch");
    scope (success)
        rig.close();

    auto app = new ExplorerApp(Root(dir: "."), "**/*.md | **/dub.sdl");
    app.layout = ExplorerApp.Layout.touch;
    app.cellDp = cellH / density;
    keep(shoot(rig, *app, null), "stats");
    keep(shoot(rig, *app, [keyEvent(Key.f1)]), "help");
}
